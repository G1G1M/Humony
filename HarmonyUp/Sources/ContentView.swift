import SwiftUI

struct ContentView: View {
    @State private var statusText = "마이크 대기 중..."
    private let audioCapture = AudioCapture()

    var body: some View {
        VStack(spacing: 16) {
            Text("HarmonyUp — Phase 1 프로토타입")
                .font(.headline)
            Text(statusText)
                .font(.system(.title, design: .monospaced))
                .padding()
        }
        .padding()
        .onAppear(perform: startCapture)
        .onDisappear(perform: audioCapture.stop)
    }

    private func startCapture() {
        do {
            try audioCapture.start { result in
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
            }
        } catch {
            statusText = "마이크 시작 실패: \(error.localizedDescription)"
        }
    }
}
