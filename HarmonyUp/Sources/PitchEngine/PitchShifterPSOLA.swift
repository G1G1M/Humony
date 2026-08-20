import Foundation

/// 녹음된 오디오의 재생 속도(길이)는 그대로 유지하면서 피치만 바꾼다.
/// "내 목소리로 화음 만들기" 기능의 v2(`c94288b`) — `PitchShifterWSOLA`가 "화음이
/// 기계음 같다"는 피드백을 받은 뒤, 리샘플링 단계 자체를 없애고 피치 동기(pitch-synchronous)
/// 방식으로 재작성한 버전이다.
///
/// **왜 리샘플링을 안 쓰는가**: WSOLA 버전은 "시간축을 늘인 뒤 리샘플링"하는 2단계
/// 방식이었다. 리샘플링은 파형 전체를 일괄적으로 늘이거나 줄이는 연산이라, 기본주파수
/// (피치)뿐 아니라 포먼트(성도 공명 특성 — 목소리를 "그 사람 목소리"로 들리게 하는 스펙트럼
/// 형태)까지 같은 비율로 바뀌어버린다("다람쥐 소리"/"느린 테이프" 효과) — 실제로 사용자가
/// "화음이 기계음 같다"고 느낀 원인이었다. 이 버전은 리샘플링 단계 자체를 없애고, 피치
/// 동기 방식으로 다시 만들었다 — 로컬 피치 주기를 추정해서, 원본에서 그 주기 근처의 파형
/// 조각(그레인)을 "모양은 그대로 둔 채" 더 자주 또는 더 뜸하게 재생만 다르게 해서 피치를
/// 바꾼다. 그레인 파형 자체를 늘이거나 줄이지 않으므로 포먼트가 보존된다.
///
/// **되살린 이유(2026-08-20)**: 이후 WORLD 보코더(`PitchShifterWorld`)로 다시 교체됐는데,
/// WORLD로도 "화음이 이상하게 들린다"는 제보가 계속돼서 — 정작 어느 알고리즘이 이 앱의
/// 화음 파이프라인(짧은 세그먼트 단위 피치시프트)에 제일 잘 맞는지 실기기로 직접 A/B
/// 비교해보기 위해 git 히스토리(`e1d0ff2^` = `c94288b`, WORLD로 교체되기 직전 버전)에서
/// 그대로 복원했다. **주의**: 이 알고리즘도 도입 당시 "전체 화음이 더 이상하게 들린다"는
/// 피드백으로 WORLD에 자리를 내준 전적이 있다 — `formantRatio` 개념 자체가 없다(WORLD
/// 전용, 여기선 지원 안 함, 대신 포먼트 보존 자체는 이 알고리즘의 설계 목표였다는 점이
/// WORLD와 다르다).
enum PitchShifterPSOLA {

    /// - Parameters:
    ///   - samples: 원본 오디오(모노, [-1, 1] 범위)
    ///   - pitchRatio: 목표 주파수 / 원래 주파수. 1보다 크면 높은 음(예: 장3도 위 = 2^(4/12)).
    ///   - expectedFrequency: 원본 음성의 대략적인 기본 주파수(Hz)를 알고 있다면 넘긴다.
    ///     로컬 피치를 못 찾는 구간(무음, 잡음)의 대체값(fallback)으로 쓴다. 모르면 nil —
    ///     그런 구간은 200Hz 근처의 임의 기본값으로 대체된다(피치 검출 실패한 구간이라
    ///     정확한 값이 아니어도 결과에 큰 영향은 없다).
    /// - Returns: 길이는 원본과 같고, 피치만 pitchRatio배 된 오디오.
    static func shift(samples: [Float], pitchRatio: Double, sampleRate: Double, expectedFrequency: Double? = nil) -> [Float] {
        guard !samples.isEmpty, pitchRatio > 0 else { return samples }
        let periods = estimateLocalPeriods(samples: samples, sampleRate: sampleRate, fallbackFrequency: expectedFrequency)
        return pitchSynchronousResynthesize(samples: samples, periods: periods, pitchRatio: pitchRatio)
    }

    // MARK: - 1단계: 로컬 피치 주기 추정

    // 로컬 F0 추정용 분석 윈도우 — MelodySegmenter와 같은 이유(AudioCapture가 이미 80Hz까지
    // 검증해둔 크기)로 2048을 그대로 쓰되, 홉은 훨씬 촘촘하게(1/8) 잡아서 피치가 빠르게
    // 움직이는 구간(글라이드, 비브라토)도 잘 따라가게 한다.
    private static let analysisWindowSize = 2048
    private static let analysisHop = 256

    /// 버퍼의 각 샘플 위치마다 "그 지점의 로컬 피치 주기(샘플 수)"를 추정한다 — 결과 배열은
    /// `samples`와 길이가 같다. 무음이거나 피치를 못 찾은 구간은 마지막으로 유효했던 주기를
    /// 그대로 이어쓴다(hold) — 매번 fallback으로 되돌리면 그 경계에서 주기가 뚝 끊겨
    /// 그레인 배치가 들쭉날쭉해진다.
    static func estimateLocalPeriods(samples: [Float], sampleRate: Double, fallbackFrequency: Double?) -> [Double] {
        let fallbackPeriod = sampleRate / (fallbackFrequency.map { $0 > 0 ? $0 : 200.0 } ?? 200.0)
        var periods = [Double](repeating: fallbackPeriod, count: samples.count)
        guard samples.count >= analysisWindowSize else { return periods }

        var lastPeriod = fallbackPeriod
        var start = 0
        while start + analysisWindowSize <= samples.count {
            let end = start + analysisWindowSize
            let window = Array(samples[start..<end])
            if VoiceActivityDetector.isVoiceActive(samples: window),
               let candidate = YINPitchDetector.detectPitch(samples: window, sampleRate: sampleRate).first,
               candidate.frequency > 0 {
                lastPeriod = sampleRate / candidate.frequency
            }
            for i in start..<min(end, periods.count) { periods[i] = lastPeriod }
            start += analysisHop
        }
        // 마지막 분석 윈도우 이후(analysisWindowSize보다 짧게 남은 꼬리)는 마지막 값으로 채운다.
        if start < periods.count {
            for i in start..<periods.count { periods[i] = lastPeriod }
        }
        return periods
    }

    // MARK: - 2단계: 피치 동기 재합성(리샘플링 없음)

    // 그레인 길이가 너무 짧으면(추정 주기가 비정상적으로 작으면) 음색이 뭉개지고, 너무 길면
    // (무음 구간의 기본값 등) 계산이 불필요하게 무거워진다 — 합리적인 범위로 clamp한다.
    private static let minHalfGrainLength = 16
    private static let maxHalfGrainLength = 2048

    /// 읽는 위치(`readPos`, 원본을 훑는 속도)와 쓰는 위치(`writePos`, 출력에 그레인을 배치하는
    /// 속도)를 서로 다른 속도로 따로 전진시킨다 — 이 "따로 감"이 피치를 바꾸는 핵심이다.
    /// 그레인 내용은 `readPos` 근방에서 그대로(리샘플링 없이) 뽑아서, `writePos` 위치에
    /// 옮겨 붙인다. `readPos`는 매번 원래 로컬 주기만큼, `writePos`는 그 주기를 pitchRatio로
    /// 나눈 값(더 짧거나 더 긴 간격)만큼 전진하므로, 두 위치는 갈수록 벌어진다 — 그 결과
    /// 출력에서 그레인이 재배치되는 간격 자체가 원본 주기와 달라져서(더 촘촘하면 높은 음,
    /// 더 성글면 낮은 음) 피치가 바뀐다. 그레인 파형 자체는 원본에서 그대로 잘라온 것이라
    /// 포먼트(스펙트럼 모양)는 바뀌지 않는다.
    ///
    /// (처음엔 읽는 위치와 쓰는 위치를 같은 값으로 뒀었는데, 그러면 겹치는 그레인들이 전부
    /// 원본의 "같은" 샘플 값을 서로 다른 가중치로만 더하는 셈이 되어 — 같은 값의 가중평균은
    /// 그 값 그대로이므로 — 피치가 전혀 안 바뀌는 문제가 있었다. 그레인이 뽑힌 위치와
    /// 옮겨 붙는 위치가 실제로 달라야 한다.)
    ///
    /// 부작용: pitchRatio가 1에서 멀수록(특히 1보다 작을 때, 예: 베이스=0.5) `readPos`가
    /// `writePos`보다 느리게/빠르게 움직여서 원본의 일부만 쓰이고 나머지는 못 쓰는 경우가
    /// 생길 수 있다 — 시간축을 그대로 유지한 채(리샘플링 없이) 피치만 바꾸는 모든 방식이
    /// 공유하는 근본적인 한계다(짧은 목소리 클립에서는 대체로 눈에 띄지 않는다).
    static func pitchSynchronousResynthesize(samples: [Float], periods: [Double], pitchRatio: Double) -> [Float] {
        guard !samples.isEmpty else { return samples }

        var output = [Float](repeating: 0, count: samples.count)
        var weight = [Float](repeating: 0, count: samples.count)
        let lastIndex = samples.count - 1

        var readPos = 0.0
        var writePos = 0.0
        while writePos < Double(samples.count) {
            let readCenter = min(max(Int(readPos.rounded()), 0), lastIndex)
            let localPeriod = periods[readCenter]
            let step = localPeriod / pitchRatio

            // 그레인 반경은 "원본 로컬 주기"의 절반(전체 그레인 ≈ 주기 1개) — 실제 목소리에
            // 가까운(배음이 풍부한) 신호로 검증한 값이다. 그레인을 이보다 넓게(주기 1~2개)
            // 잡으면, 그레인 하나 안에 원본 파형의 주기가 여러 번 들어가버려서 — 겹쳐 더한
            // 그레인들의 "재생 간격(step)"보다 그레인 자체가 담고 있는 원래 주파수 성분이
            // 더 강하게 남아, 특히 피치를 크게 낮출 때(예: 베이스, step이 주기의 2배) 원래
            // 주파수가 그대로 다시 검출되는 문제가 실측(유닛테스트)으로 확인됐다. 그레인을
            // 주기 1개 폭(반경 0.5배)으로 좁히면 이 문제는 해결되지만, 대신 그레인 길이가
            // step보다 짧아지는 경우(피치를 크게 낮출 때) 그레인 사이에 커버 안 되는(무음)
            // 짧은 틈이 생길 수 있다 — 그건 아래 weight==0 구간을 선형 보간으로 메워서 처리한다.
            let halfLength = min(maxHalfGrainLength, max(minHalfGrainLength, Int(localPeriod * 0.5)))
            let grainLength = halfLength * 2
            let readStart = readCenter - halfLength
            let writeCenter = Int(writePos.rounded())
            let writeStart = writeCenter - halfLength
            let window = hannWindow(size: grainLength)

            for i in 0..<grainLength {
                let sourceIndex = readStart + i
                let outIndex = writeStart + i
                guard sourceIndex >= 0, sourceIndex <= lastIndex, outIndex >= 0, outIndex < output.count else { continue }
                let w = window[i]
                output[outIndex] += samples[sourceIndex] * w
                weight[outIndex] += w
            }

            readPos += localPeriod
            writePos += step
        }

        for i in 0..<output.count where weight[i] > 0.0001 {
            output[i] /= weight[i]
        }
        fillUncoveredGapsInPlace(&output, weight: weight)
        return output
    }

    /// 어떤 그레인도 닿지 않은(weight가 계속 0인) 구간은 디지털 무음(정확히 0)으로 남는다 —
    /// 그대로 두면 재생할 때 뚝뚝 끊기는 클릭음으로 들릴 수 있다. 짧은 틈이라 정교하게
    /// 복원할 필요는 없고, 양옆의 실제로 덮인 샘플 사이를 선형으로 이어주는 것만으로
    /// 충분하다(사람 귀에는 매끄러운 전환처럼 들린다).
    private static func fillUncoveredGapsInPlace(_ output: inout [Float], weight: [Float]) {
        var i = 0
        while i < output.count {
            guard weight[i] <= 0.0001 else { i += 1; continue }
            var gapEnd = i
            while gapEnd < output.count, weight[gapEnd] <= 0.0001 { gapEnd += 1 }

            let leftValue = i > 0 ? output[i - 1] : (gapEnd < output.count ? output[gapEnd] : 0)
            let rightValue = gapEnd < output.count ? output[gapEnd] : leftValue
            let gapLength = gapEnd - i
            for offset in 0..<gapLength {
                let t = Float(offset + 1) / Float(gapLength + 1)
                output[i + offset] = leftValue * (1 - t) + rightValue * t
            }
            i = gapEnd
        }
    }

    /// 반달 모양 창(Hann window) — 그레인의 시작과 끝을 0으로 부드럽게 줄여서, 겹쳐 더할 때
    /// 이음매에서 클릭음(불연속)이 나지 않게 한다.
    private static func hannWindow(size: Int) -> [Float] {
        guard size > 1 else { return [1.0] }
        return (0..<size).map { i in
            Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(size - 1)))
        }
    }
}
