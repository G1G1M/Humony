import SwiftUI

struct ContentView: View {
    @State private var statusText = "마이크 대기 중..."
    @State private var keyText = ""
    @State private var harmonyText = ""
    @State private var isPlayingTone = false
    @State private var tonePlaybackTask: Task<Void, Never>?

    private let audioCapture = AudioCapture()
    private let melodySession = MelodySession()
    private let tonePlayer = TonePlayer()

    // 화음의 각 음을 순서대로 들려줄 때 한 음당 재생하는 길이.
    private let noteHoldDuration: Duration = .milliseconds(800)

    var body: some View {
        VStack(spacing: 16) {
            Text("HarmonyUp — Phase 3 프로토타입")
                .font(.headline)
            Text(statusText)
                .font(.system(.title, design: .monospaced))
            if !keyText.isEmpty {
                Text(keyText).font(.subheadline)
            }
            if !harmonyText.isEmpty {
                Text(harmonyText).font(.subheadline)
            }
            Button(isPlayingTone ? "화음 정지" : "화음 듣기 (3도→5도)", action: toggleTonePlayback)
                .disabled(melodySession.suggestedHarmony == nil && !isPlayingTone)
            Button("다시 시작", action: resetSession)
        }
        .padding()
        .onAppear(perform: startCapture)
        .onDisappear {
            tonePlaybackTask?.cancel()
            audioCapture.stop()
            tonePlayer.stop()
        }
    }

    private func startCapture() {
        do {
            try audioCapture.start { result in
                // 화음 재생 중엔 마이크 입력을 완전히 무시한다 — 안 그러면 스피커로 낸 화음 소리가
                // 다시 마이크로 들어가서 "새로 부른 음"으로 인식되고, 거기에 또 화음이 붙는 피드백 루프가 생긴다.
                guard !isPlayingTone else { return }

                melodySession.record(result)

                guard let result else {
                    statusText = "..."
                    return
                }

                let line = String(
                    format: "%@  %.1fHz  (%+.1f cent, 신뢰도 %.2f)",
                    result.noteName, result.frequency, result.centsOffset, result.confidence
                )
                statusText = line
                print(line) // Phase 1 완료 조건: 감지된 결과를 콘솔에 실시간 출력

                if let key = melodySession.detectedKey {
                    keyText = String(format: "조성: %@ (확신도 %.2f)", key.name, key.confidence)
                }

                if let harmony = melodySession.suggestedHarmony {
                    let names = harmony
                        .map { NoteNameConverter.convert(frequency: $0.frequency)?.noteName ?? "?" }
                        .joined(separator: ", ")
                    harmonyText = "화음 제안: \(names)"
                } else {
                    harmonyText = ""
                }
            }
        } catch {
            statusText = "마이크 시작 실패: \(error.localizedDescription)"
        }
    }

    private func toggleTonePlayback() {
        if isPlayingTone {
            tonePlaybackTask?.cancel()
            tonePlaybackTask = nil
            tonePlayer.stop()
            isPlayingTone = false
            return
        }

        // 버튼을 누른 시점의 화음으로 고정한다 — 재생 중엔 마이크를 무시하므로 어차피 갱신될 일은 없지만,
        // "다시 시작을 누르기 전까지는 이 음에 대한 화음만 듣는다"는 의도를 코드로도 명확히 드러낸다.
        guard let lockedHarmony = melodySession.suggestedHarmony, !lockedHarmony.isEmpty else { return }

        do {
            try tonePlayer.start()
            isPlayingTone = true
        } catch {
            statusText = "재생 실패: \(error.localizedDescription)"
            return
        }

        tonePlaybackTask = Task {
            await playHarmonyNotesInSequence(lockedHarmony)
        }
    }

    /// 고정된 화음의 각 음(3도, 5도)을 하나씩 순서대로 들려주는 걸 정지할 때까지 반복한다.
    private func playHarmonyNotesInSequence(_ harmony: [ChordGenerator.HarmonyNote]) async {
        while !Task.isCancelled {
            for note in harmony {
                guard !Task.isCancelled else { return }
                tonePlayer.setFrequency(note.frequency)
                try? await Task.sleep(for: noteHoldDuration)
            }
        }
    }

    private func resetSession() {
        tonePlaybackTask?.cancel()
        tonePlaybackTask = nil
        tonePlayer.stop()
        isPlayingTone = false
        melodySession.reset()
        keyText = ""
        harmonyText = ""
        statusText = "..."
    }
}
