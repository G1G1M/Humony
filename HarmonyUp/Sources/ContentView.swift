import SwiftUI

struct ContentView: View {
    @State private var statusText = "마이크 대기 중..."
    @State private var keyText = ""
    @State private var harmonyText = ""
    @State private var isPlayingTone = false

    private let audioCapture = AudioCapture()
    private let melodySession = MelodySession()
    private let tonePlayer = TonePlayer()

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
            Button(isPlayingTone ? "화음 정지" : "화음 듣기 (3도)", action: toggleTonePlayback)
                .disabled(melodySession.suggestedHarmony == nil && !isPlayingTone)
            Button("다시 시작", action: resetSession)
        }
        .padding()
        .onAppear(perform: startCapture)
        .onDisappear {
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

                    // 재생 중이면 노래가 이어지는 동안에도 목표음이 최신 화음 제안을 계속 따라가게 한다.
                    if isPlayingTone, let third = harmony.first(where: { $0.interval == .third }) {
                        tonePlayer.setFrequency(third.frequency)
                    }
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
            tonePlayer.stop()
            isPlayingTone = false
            return
        }

        guard let harmony = melodySession.suggestedHarmony,
              let third = harmony.first(where: { $0.interval == .third }) else { return }

        do {
            try tonePlayer.start()
            tonePlayer.setFrequency(third.frequency)
            isPlayingTone = true
        } catch {
            statusText = "재생 실패: \(error.localizedDescription)"
        }
    }

    private func resetSession() {
        melodySession.reset()
        keyText = ""
        harmonyText = ""
        statusText = "..."
    }
}
