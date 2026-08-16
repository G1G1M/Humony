import Foundation

/// 화음 성부(베이스/3도/5도) 각각을 살짝 지연 + 미세하게 디튠한 복사본과 섞어서, 한 사람의
/// 목소리를 피치만 옮긴 게 아니라 "다른 사람이 한 번 더 같이 부른" 듯한 두께를 만든다.
/// 실제 스튜디오의 ADT(Automatic Double Tracking)/보컬 더블링 기법을 흉내낸다(docs/CONCEPTS.md
/// 49절 참고) — 원본과 복사본을 지연+디튠으로 살짝 어긋나게 만들고 원본보다 작은 레벨로 섞으면,
/// 완전히 겹쳐 재생할 때보다 훨씬 "여러 사람이 함께 부르는" 느낌이 난다.
enum VoiceDoubler {

    /// 성부마다 지연/디튠 값을 다르게 둬야 한다 — 네 성부가 전부 똑같은 패턴으로 출렁이면
    /// 오히려 인공적으로 들린다(자연에는 그런 완벽한 동기화가 없다). 값 자체는 ADT 플러그인이
    /// 흔히 쓰는 범위(지연 15~35ms, 디튠 몇 센트 이내)를 참고해서 성부별로 조금씩 다르게 골랐다.
    static func apply(to samples: [Float], sampleRate: Double, interval: ChordGenerator.Interval) -> [Float] {
        let delayMilliseconds: Double
        let detuneCents: Double
        switch interval {
        case .bass:
            delayMilliseconds = 22
            detuneCents = -6
        case .third:
            delayMilliseconds = 18
            detuneCents = 8
        case .fifth:
            delayMilliseconds = 27
            detuneCents = -4
        }
        return double(samples: samples, sampleRate: sampleRate, delayMilliseconds: delayMilliseconds, detuneCents: detuneCents)
    }

    /// - Parameter mixLevel: 복사본을 원본 대비 어느 정도 크기로 섞을지(0~1). 너무 크면 화음이
    ///   아니라 디튠된 불협화음처럼 들려서, 정석 더블링 믹스 비율(복사본은 원본보다 확실히
    ///   작게)을 따라 0.45로 둔다.
    static func double(
        samples: [Float],
        sampleRate: Double,
        delayMilliseconds: Double,
        detuneCents: Double,
        mixLevel: Float = 0.45
    ) -> [Float] {
        guard !samples.isEmpty, delayMilliseconds > 0 else { return samples }

        // 몇 센트(반음의 일부) 수준의 미세 디튠은 WORLD 풀 분석(F0/포먼트/비주기성 추정)을 쓸
        // 만큼 크지 않다 — 실제 아날로그 ADT도 테이프 속도를 살짝 흔드는 것뿐이라(포먼트 보정
        // 없음) 간단한 선형 보간 리샘플링만으로 충분하고, 오히려 이 "약간의 포먼트 흔들림"이
        // 진짜 다른 사람이 부른 것 같은 자연스러움을 만들어준다.
        let detuneRatio = pow(2.0, detuneCents / 1200.0)
        let retuned = resamplePitch(samples, ratio: detuneRatio)

        let delaySampleCount = Int(sampleRate * delayMilliseconds / 1000.0)
        var result = samples
        for i in 0..<samples.count {
            let sourceIndex = i - delaySampleCount
            guard sourceIndex >= 0, sourceIndex < retuned.count else { continue }
            result[i] += retuned[sourceIndex] * mixLevel
        }
        return result
    }

    /// 재생 속도를 바꾸듯 원본을 `ratio`배 빠르게(피치는 올라가고 길이는 짧아짐) 또는 느리게
    /// (피치는 내려가고 길이는 길어짐) 읽어서 리샘플한다 — 옛날 테이프 ADT가 속도를 살짝
    /// 흔들던 것과 같은 원리를 그대로 구현한 것.
    private static func resamplePitch(_ samples: [Float], ratio: Double) -> [Float] {
        guard ratio > 0, !samples.isEmpty else { return samples }
        let outputCount = max(1, Int(Double(samples.count) / ratio))
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let sourcePosition = Double(i) * ratio
            let index0 = Int(sourcePosition)
            guard index0 < samples.count - 1 else {
                output[i] = index0 < samples.count ? samples[index0] : 0
                continue
            }
            let fraction = Float(sourcePosition - Double(index0))
            output[i] = samples[index0] * (1 - fraction) + samples[index0 + 1] * fraction
        }
        return output
    }
}
