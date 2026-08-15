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
                // 목표음 재생 중 주파수 갱신은 재생 루프(playHarmonyNotesInSequence)가 담당한다 —
                // 여기서 매 프레임 직접 건드리면 재생 루프와 서로 값을 덮어써서 음이 지저분하게 흔들린다.
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

        guard melodySession.suggestedHarmony != nil else { return }

        do {
            try tonePlayer.start()
            isPlayingTone = true
        } catch {
            statusText = "재생 실패: \(error.localizedDescription)"
            return
        }

        tonePlaybackTask = Task {
            await playHarmonyNotesInSequence()
        }
    }

    /// 화음의 각 음(3도, 5도)을 하나씩 순서대로 들려주는 걸 정지할 때까지 반복한다.
    /// 매 바퀴 melodySession.suggestedHarmony를 다시 읽어서, 그사이 멜로디가 바뀌었으면
    /// 다음 바퀴부터 최신 화음을 재생한다.
    private func playHarmonyNotesInSequence() async {
        while !Task.isCancelled {
            guard let harmony = melodySession.suggestedHarmony, !harmony.isEmpty else { break }

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
