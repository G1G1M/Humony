import Foundation

/// "내 목소리로 화음 만들기"용 롤링 버퍼(`recentVoiceBuffer`)는 음이 바뀌어도 상관없이
/// 항상 최근 N초를 그대로 유지한다(버튼을 누르는 타이밍과 무관하게 방금 부른 걸 쓰기 위해
/// 도입한 방식 — `docs/CONCEPTS.md` 20절 참고). 그런데 그 안에는 지금 화음의 기준이 된
/// 음 말고도, 그 이전에 부르던 다른 음이나 숨소리/발음 시작 잡음이 섞여 있을 수 있다.
/// 그걸 그대로 통째로 피치 시프트하면 "한 음"이 아니라 "음이 움직이는 구간"을 그대로
/// 옮기는 셈이라, 재생했을 때 화음의 음정이 왔다갔다하는 것처럼 들린다.
enum VoiceSegmentTrimmer {

    /// 버퍼의 맨 끝(가장 최근)부터 거슬러 올라가며, 목표 주파수와 `toleranceCents` 이내로
    /// 가까운 동안만 계속 포함시켜서 "최근의 안정된 한 음" 구간만 잘라낸다.
    /// 안정된 구간을 하나도 못 찾으면(예: 목소리가 이미 흔들리는 채로 끝났거나, 버퍼가 너무
    /// 짧아서 분석 윈도우가 하나도 안 나오는 경우) 잘라내지 않고 원본을 그대로 반환한다 —
    /// "화음이 아예 안 들리는" 것보다는 "예전처럼 다소 불안정하게라도 들리는" 쪽이 안전하다.
    static func trimToStableSegment(
        samples: [Float],
        sampleRate: Double,
        targetFrequency: Double,
        toleranceCents: Double = 60,
        windowSize: Int = 1024,
        hop: Int = 512
    ) -> [Float] {
        guard samples.count > windowSize, targetFrequency > 0 else { return samples }

        // 분석 윈도우 시작 위치를 뒤(최신)에서부터 hop 간격으로 나열한다.
        var windowStarts: [Int] = []
        var start = samples.count - windowSize
        while start >= 0 {
            windowStarts.append(start)
            start -= hop
        }
        windowStarts.reverse() // 과거 -> 최근 순으로 정렬

        // 가장 최근 윈도우부터 거슬러 올라가면서, 목표음과 가까운 동안만 "포함 시작 지점"을 앞으로 당긴다.
        // 버퍼는 이제(24절) VAD/피치 검출 성공 여부와 무관하게 원본을 그대로 담기 때문에,
        // 맨 끝에 노래를 마친 뒤의 짧은 무음 꼬리가 섞여 있을 수 있다 — 아직 "진짜 소리"에
        // 도달하기 전(reachedVoicedRegion == false)의 무음은 그냥 건너뛰고, 한 번 소리 구간에
        // 들어선 뒤에 다시 무음이 나오면 그건 음과 음 사이의 진짜 경계이므로 거기서 멈춘다.
        var earliestKeptIndex: Int?
        var reachedVoicedRegion = false
        for index in windowStarts.indices.reversed() {
            let windowStart = windowStarts[index]
            let window = Array(samples[windowStart..<(windowStart + windowSize)])

            guard VoiceActivityDetector.isVoiceActive(samples: window) else {
                if reachedVoicedRegion { break }
                continue
            }
            reachedVoicedRegion = true

            guard let candidate = YINPitchDetector.detectPitch(samples: window, sampleRate: sampleRate).first else {
                break
            }
            let cents = abs(1200.0 * log2(candidate.frequency / targetFrequency))
            guard cents <= toleranceCents else { break }
            earliestKeptIndex = index
        }

        guard let earliestKeptIndex else { return samples }

        let trimStart = windowStarts[earliestKeptIndex]
        let trimmed = Array(samples[trimStart...])

        // 너무 짧게 잘리면(예: 0.1초 미만) WSOLA 그레인(약 23ms)이 몇 개 안 남아 오히려
        // 부자연스러워질 수 있다 — 이럴 땐 자르지 않은 원본을 쓰는 게 낫다.
        let minimumSampleCount = Int(sampleRate * 0.2)
        guard trimmed.count >= minimumSampleCount else { return samples }

        return trimmed
    }
}
