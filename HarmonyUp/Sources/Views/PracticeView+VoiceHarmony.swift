import SwiftUI

/// 화음이 멜로디와 싱크가 안 맞는다는 실기기 피드백(95·96절 이후에도 남음)에 대한 다음 실험 —
/// `VoiceDoubler`(성부 두께감을 위한 지연+디튠 복사본 믹싱) 자체가 원본 위에 15~35ms 지연된
/// 겹침을 한 겹 더 얹는 구조라, 그 겹침이 여전히 어택을 미세하게 부드럽게 만드는 요인일 수
/// 있다는 가설을 검증하기 위해 끈다. `false`로 끄면 "합창처럼 두꺼운" 느낌은 줄지만 가장
/// 깨끗하고 즉각적인 어택을 들을 수 있다 — 청취 결과로 다음(재도입/약하게/PSOLA 회귀 검토)을
/// 정한다(docs/CONCEPTS.md 참고).
private let isVoiceDoublingEnabled = false

/// `PracticeView`의 "내 목소리로 화음" 재생 책임 — 성부별 화음 트랙 계산(WORLD 피치시프트),
/// 재생, 카라오케 재생헤드 동기화/햅틱까지. 나머지 책임은 `PracticeView.swift`(상태/body),
/// `PracticeView+Layout.swift`(레이아웃), `PracticeView+Scoring.swift`(채점),
/// `PracticeView+Capture.swift`(녹음/분석)에 있다.
extension PracticeView {
    var voiceHarmonyPanel: some View {
        HarmonyCard("내 목소리로 화음", systemImage: "music.mic", iconColor: Theme.voiceAccent) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // 버튼보다 먼저 설명을 둬서, 뭘 누르기 전에 "이게 뭘 하는 버튼인지"부터 읽히게 한다.
                Text(String(format: "방금 녹음한 노래를 그대로 베이스/3도/5도로 옮겨서 들려줘요 (확보된 목소리: %.1f초)",
                            Double(recentVoiceBuffer.count) / recentVoiceSampleRate))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                // 성부별 뮤트 토글 — 눌러서 재생에 포함/제외할 성부를 자유롭게 고른다. "내 목소리로
                // 베이스/3도/5도"를 각각 따로 미리듣는 버튼은 이 토글로 성부 하나만 켜고 재생하면
                // 결과가 같아서(오히려 pan까지 적용돼 더 일관됨) 따로 두지 않고 하나로 합쳤다 —
                // 버튼 수를 줄여 카드를 더 단순하게 다듬었다.
                ViewThatFits {
                    HStack {
                        ForEach(PlaybackVoice.allCases, id: \.self) { voice in
                            VoiceToggleChip(voice: voice, mutedVoices: $mutedVoices)
                        }
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(PlaybackVoice.allCases, id: \.self) { voice in
                            VoiceToggleChip(voice: voice, mutedVoices: $mutedVoices)
                        }
                    }
                }

                playEnabledVoicesButton
                    .harmonyButtonStyle(prominent: true)
                    .frame(maxWidth: .infinity)
                    // "지금 쓸 수 있는 녹음이 있는지"만 본다 — isCapturing(마이크가 지금 열려
                    // 있는지)로 막으면, 녹음을 다 마친 뒤(=isCapturing이 이미 false) 정작 이
                    // 버튼을 못 누르는 문제가 있었다(실제로 겪은 버그). isScoreRendering은 더 이상
                    // 안 본다 — 화음 트랙이 녹음 직후 미리 계산돼 있어서(precomputeHarmonyTracks),
                    // 재생이 악보 렌더링을 기다릴 이유가 없어졌다.
                    .disabled(recentVoiceBuffer.isEmpty || isPlaybackBusy)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 켜져 있는 성부만 골라 동시에 재생한다 — 예전엔 "전체 화음"(전부 켜짐 고정)과 "화음만
    /// 듣기"(멜로디만 고정으로 꺼짐) 두 버튼으로 나뉘어 있던 걸, 토글로 자유롭게 조합할 수 있게
    /// 일반화했다(로드맵 Phase 4, docs/CONCEPTS.md 53절).
    var playEnabledVoicesButton: some View {
        Button {
            playHarmonizedVoice(startStepIndex: nil)
        } label: {
            Label("재생", systemImage: "play.fill")
        }
    }

    /// 화음이 계산된 그 음을 기준으로, 목표 interval(3도/5도) 위 주파수까지의 배율(pitchRatio)을 구한다.
    /// 분모는 `lastNote`(진짜 마지막 음)가 아니라 `suggestedHarmonyBaseFrequency`를 써야 한다 —
    /// 녹음이 온음계 밖 음으로 끝나서 화음이 그보다 앞선 음 기준으로 나온 경우, 마지막 음으로
    /// 나누면 화음과 안 맞는 엉뚱한 비율이 나온다(MelodySession.swift 주석 참고).
    ///
    /// `playHarmonizedVoice`가 실제 재생 트랙을 만들 때는 이 값을 쓰지 않는다(스텝마다 자기
    /// 화음으로 따로 계산 — `harmonizedTrack(interval:startStepIndex:startTime:rate:)` 참고).
    /// 여기서는 "화음이 아예 있는지"를 확인하는 가벼운 존재 확인 용도로만 남겨뒀다.
    func pitchRatio(toInterval interval: ChordGenerator.Interval) -> Double? {
        guard let baseFrequency = melodySession.suggestedHarmonyBaseFrequency,
              let harmony = melodySession.suggestedHarmony,
              let target = harmony.first(where: { $0.interval == interval }) else { return nil }
        return target.frequency / baseFrequency
    }

    /// 성부 하나(베이스/3도/5도)의 재생 트랙을 멜로디 스텝 단위로 만든다. 예전엔 화음 전체를
    /// (마지막 음 기준) 고정 비율 하나로 통째로 옮겼는데, 여러 음으로 된 멜로디에서는 음마다
    /// 실제 화음이 다른데 비율은 하나로 고정돼 있어서 앵커 음이 아닌 나머지 음들에서 화음이
    /// 어긋나 불협화음처럼 들렸다("메인 멜로디는 괜찮은데 화음이 거슬린다" 실사용 피드백으로
    /// 원인 확정). 이제 각 스텝을 자기 구간(`onsetTime`~`onsetTime+duration`)만큼만 잘라서 그
    /// 스텝 자신의 화음 목표 주파수로 각각 피치시프트한 뒤 이어붙인다. 스텝에 이 성부의 화음이
    /// 없으면(온음계 밖 음 등, 악보에도 쉼표로 표시되는 것과 같은 경우) 무음으로 채워서 재생
    /// 타이밍(재생헤드 매핑, 멜로디 트랙과의 동기)은 그대로 유지한다 — 스텝 사이의 빈틈도
    /// 무음으로 메워서, 결과 트랙 길이가 `recorded`(멜로디 트랙)와 정확히 같게 만든다.
    func harmonizedTrack(interval: ChordGenerator.Interval, startStepIndex: Int?, startTime: Double, rate: Double) -> [Float] {
        let startIndex = startStepIndex ?? 0
        guard melodySteps.indices.contains(startIndex) else { return [] }

        // 세그먼트 경계에서 나는 클릭음을 없애는 짧은 페이드 — 클릭 방지에 필요한 최소한만
        // 쓴다(harmonySegmentFadeDuration 선언부 참고 — 너무 길면 매 음의 공격이 부드러워져
        // "화음이 박자보다 밀려 들린다"는 인상을 만든다).
        let segmentFadeCount = max(1, Int(rate * harmonySegmentFadeDuration))
        let bufferEnd = recentVoiceBuffer.count
        let maxBridgeableGapSamples = Int(rate * maxHarmonyGapBridgeDuration)
        var output: [Float] = []
        var cursor = max(0, min(bufferEnd, Int(startTime * rate)))

        // raw 구간을 targetFrequency로 피치시프트 + (필요시)더블링 + 페이드까지 마친 청크로
        // 만든다. fadeIn/fadeOut을 따로 받는 이유는 아래에서 "이어 부른 여러 음을 하나로
        // 묶은 런(run)"을 통째로 한 번만 시프트하기 때문 — 런의 맨 처음에만 페이드 인,
        // 맨 끝에만 페이드 아웃을 걸어야 안쪽(원래 음 경계였던 자리)에 미세한 골이 안 남고
        // 진짜로 끊김 없이 이어 들린다("이음표처럼 이어져야 할 음이 화음에서 여전히 살짝
        // 끊겨 들린다"는 재확인 피드백 — 예전엔 브리지 구간도 별도 청크로 취급해 그 경계마다
        // 짧게라도 페이드가 걸렸었다).
        func pitchShiftedChunk(raw: [Float], sourceMIDINote: Int, targetFrequency: Double, fadeIn: Bool, fadeOut: Bool) -> [Float] {
            let ratio = targetFrequency / NoteNameConverter.frequency(forMIDINote: sourceMIDINote)
            let shifted = PitchShifter.shift(samples: raw, pitchRatio: ratio, formantRatio: interval.formantRatio, sampleRate: rate)
            // 더블링은 반드시 이 청크 하나의 구간 안에서만 적용한다 — 예전엔 스텝별로 피치시프트한
            // 조각들을 전부 이어붙인 "성부 전체 트랙"에 한 번에 더블링을 걸었는데, 그러면
            // 각 음의 시작 지점(더블링 지연 15~35ms 구간)에 "직전 음의 피치로 지연·디튠된
            // 복사본"이 새어 들어와서 음이 바뀔 때마다 화음이 어긋나 들렸다("화음이 안 맞는
            // 느낌이 너무 강하다" 실사용 피드백으로 발견, 근거: VoiceDoubler.double이 델레이
            // 오프셋만큼 과거 샘플을 그대로 참조하는데, 그 "과거"가 이 음이 아니라 이전
            // 음이었던 것). 청크(런) 단위로만 더블링하면 지연 참조가 항상 같은 런 안에서만
            // 일어나서 이 누출이 원천적으로 없어진다.
            let doubled = isVoiceDoublingEnabled ? VoiceDoubler.apply(to: shifted, sampleRate: rate, interval: interval) : shifted
            return AudioGain.applyFadeInOut(
                doubled,
                fadeInCount: fadeIn ? segmentFadeCount : 0,
                fadeOutCount: fadeOut ? segmentFadeCount : 0
            )
        }

        // 같은 음 안에서(런 안쪽) 골이 없어져도, 서로 다른 음끼리 붙어서(레가토로 이어 부른
        // 멜로디는 음 사이에 거의 틈이 없다) 넘어갈 때마다 여전히 fade-out→fade-in이 한 번씩
        // 걸려서 "뚝뚝 끊긴다"는 재확인 피드백을 받음 — 노래 한 곡엔 이런 음 전환이 수십 번
        // 있을 수 있어서, 짧은 골이라도 자주 반복되면 전체적으로 "덜컹거리는" 느낌이 쌓인다.
        // 무음(진짜 쉼표) 없이 유성음끼리 바로 붙는 전환은 fade-out/fade-in 대신 **크로스페이드**
        // (직전 런의 꼬리와 다음 런의 머리를 선형으로 겹쳐 섞기)로 이어서, 신호가 한 번도
        // 0으로 안 떨어지고 자연스럽게 넘어가게 한다. 진짜 쉼표(간격이 있는 경우)는 그대로
        // 무음으로 채우고 그 앞뒤에만 클릭 방지 페이드를 건다.
        let crossfadeCount = segmentFadeCount

        // `output`의 꼬리와 `chunk`의 머리를 선형 크로스페이드로 섞어 이어붙인다. `overlap`은
        // 반드시 `chunk`를 만들 때 실제로 원본에서 더 끌어온(overlapBorrowed) 만큼과 정확히
        // 같아야 한다 — 그래야 여기서 버리는 `chunk`의 앞부분 길이가 그 "더 끌어온" 길이와
        // 정확히 상쇄돼서 트랙 전체 길이가 보존된다(둘이 어긋나면 트랙이 조금씩 짧아지면서
        // `recentVoiceBuffer`와의 샘플 대응이 깨져 재생이 갈수록 밀리는 버그로 이어질 수 있다).
        func appendCrossfaded(_ chunk: [Float], overlap: Int) {
            let n = min(overlap, output.count, chunk.count)
            guard n > 0 else {
                output.append(contentsOf: chunk)
                return
            }
            let overlapStart = output.count - n
            for k in 0..<n {
                let t = Float(k) / Float(n)
                output[overlapStart + k] = output[overlapStart + k] * (1 - t) + chunk[k] * t
            }
            output.append(contentsOf: chunk[n...])
        }

        // 직전에 append된 런이 무음 없이 끝났고(=다음 런과 바로 이어붙을 수 있고), 크로스페이드
        // 대상이 될 수 있도록 자기 끝을 페이드아웃하지 않은 채로 끝났는지.
        var previousRunEndsAdjacentUnfaded = false

        var i = startIndex
        while i < melodySteps.count {
            let step = melodySteps[i]
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0 else {
                i += 1
                continue
            }
            let segStart = max(0, Int(onset * rate))
            let segEnd = min(bufferEnd, Int((onset + duration) * rate))
            guard segStart < segEnd else {
                i += 1
                continue
            }

            guard let target = step.harmony?.first(where: { $0.interval == interval }) else {
                // 이 성부의 화음이 없는 스텝(쉼표) — 무음.
                if segStart > cursor {
                    output.append(contentsOf: [Float](repeating: 0, count: segStart - cursor))
                }
                output.append(contentsOf: [Float](repeating: 0, count: segEnd - segStart))
                cursor = segEnd
                previousRunEndsAdjacentUnfaded = false
                i += 1
                continue
            }

            let hasGapBeforeThisRun = segStart > cursor
            if hasGapBeforeThisRun {
                output.append(contentsOf: [Float](repeating: 0, count: segStart - cursor))
            }
            let shouldCrossfadeIn = previousRunEndsAdjacentUnfaded && !hasGapBeforeThisRun

            // 이 스텝부터 시작해서, "같은 멜로디 음 + 브리징 가능한 간격"으로 이어지는 다음
            // 스텝들을 계속 흡수한다 — 원래 여러 스텝으로 갈라져 있던 하나의 held 음을 런
            // (run) 하나로 묶어서, 이 런 전체를 한 번의 피치시프트 호출로 처리한다(런 안쪽엔
            // 페이드가 전혀 없다). v1 화성 모델(102절)에서는 같은 멜로디 음이면 화음 목표도
            // 항상 같으므로, 멜로디 음이 같은지만 확인하면 충분하다.
            var runEnd = segEnd
            var j = i + 1
            while j < melodySteps.count {
                let nextStep = melodySteps[j]
                guard let nextOnset = nextStep.onsetTime, let nextDuration = nextStep.duration, nextDuration > 0,
                      nextStep.midiNote == step.midiNote else { break }
                let nextSegStart = max(0, Int(nextOnset * rate))
                let nextSegEnd = min(bufferEnd, Int((nextOnset + nextDuration) * rate))
                guard nextSegStart < nextSegEnd, nextSegStart - runEnd <= maxBridgeableGapSamples else { break }
                runEnd = nextSegEnd
                j += 1
            }

            // 다음 스텝(다른 음이어도 상관없다)이 무음 간격 없이 바로 이어지고 그 성부의
            // 화음도 있으면, 여기서 페이드아웃하지 않고 다음 런과 크로스페이드로 잇는다.
            var shouldCrossfadeOut = false
            if j < melodySteps.count, let nextOnset = melodySteps[j].onsetTime, let nextDuration = melodySteps[j].duration, nextDuration > 0 {
                let nextSegStart = max(0, Int(nextOnset * rate))
                let nextSegEnd = min(bufferEnd, Int((nextOnset + nextDuration) * rate))
                if nextSegStart < nextSegEnd, nextSegStart <= runEnd,
                   melodySteps[j].harmony?.first(where: { $0.interval == interval }) != nil {
                    shouldCrossfadeOut = true
                }
            }

            // 크로스페이드로 이어붙일 땐, 직전 런이 이미 자기 몫으로 처리한 꼬리 구간
            // (crossfadeCount 샘플)을 이 런도 한 번 더 원본에서 끌어와 자기 비율로 다시
            // 피치시프트한다 — 같은 원본을 두 배율로 각각 렌더링한 뒤 그 겹치는 구간만
            // 섞는 게 진짜 크로스페이드다. 이렇게 "겹쳐서 빌려온" 만큼을 뒤에서
            // `appendCrossfaded`가 다시 걷어내므로(섞은 뒤 청크 앞부분을 버림), 트랙 전체
            // 길이(=`recentVoiceBuffer`와의 샘플 대 샘플 대응)는 그대로 보존된다.
            let overlapBorrowed = shouldCrossfadeIn ? min(crossfadeCount, segStart) : 0
            let runRaw = Array(recentVoiceBuffer[(segStart - overlapBorrowed)..<runEnd])
            let chunk = pitchShiftedChunk(
                raw: runRaw,
                sourceMIDINote: step.midiNote,
                targetFrequency: target.frequency,
                fadeIn: !shouldCrossfadeIn,
                fadeOut: !shouldCrossfadeOut
            )
            if shouldCrossfadeIn {
                appendCrossfaded(chunk, overlap: overlapBorrowed)
            } else {
                output.append(contentsOf: chunk)
            }
            cursor = runEnd
            previousRunEndsAdjacentUnfaded = shouldCrossfadeOut
            i = j
        }

        if cursor < bufferEnd {
            output.append(contentsOf: [Float](repeating: 0, count: bufferEnd - cursor))
        }
        return output
    }

    /// 녹음 분석이 끝나자마자(재생 버튼을 누르기 전에) 성부별 화음 트랙을 미리 다 계산해서
    /// `precomputedHarmonyTracks`에 담아둔다. 예전엔 "재생" 버튼을 누른 시점에야 이 무거운
    /// WORLD 연산을 시작해서, 그 계산이 악보 렌더링(WKWebView JS)과 동시에 CPU를 다퉈 재생
    /// 오디오가 끊기는 원인이 됐다 — "재생 버튼은 이미 계산돼있는 걸 들어보기 위한 버튼이어야
    /// 하지, 누른 시점에 계산을 시작하는 버튼이면 안 된다"는 지적을 반영해 계산 시점 자체를
    /// 녹음 직후로 앞당겼다. 이러면 계산은 악보 렌더링과 겹쳐도 상관없다(둘 다 아직 스피커로
    /// 아무 소리도 안 내는 준비 단계라 CPU를 나눠 써도 사용자 귀에는 안 들림) — 진짜 위험한
    /// "실시간 오디오 출력 중 CPU 경쟁"은 재생이 실제로 시작되는 시점으로 옮겨가는데, 그때는
    /// 이미 한참 전에 계산이 끝나 있을 가능성이 높다.
    func precomputeHarmonyTracks() {
        precomputedHarmonyTracks = [:]
        let rate = recentVoiceSampleRate
        Task {
            var computed: [ChordGenerator.Interval: [Float]] = [:]
            for interval in ChordGenerator.Interval.allCases {
                computed[interval] = harmonizedTrack(interval: interval, startStepIndex: nil, startTime: 0, rate: rate)
            }
            precomputedHarmonyTracks = computed
        }
    }

    /// "내 목소리로 화음 만들기" — 방금 녹음한 소리(recentVoiceBuffer)를 `mutedVoices`에 안
    /// 들어있는(=켜진) 성부만 골라 베이스/3도/5도(+멜로디)로 피치 시프트해서 한꺼번에 동시
    /// 재생한다. 예전엔 "전체 화음"(고정 4성부)/"화음만 듣기"(멜로디 고정 제외)/"베이스·3도·
    /// 5도 각각 미리듣기" 여러 버튼으로 나뉘어 있던 걸, 토글 하나로 자유롭게 조합할 수 있게
    /// 일반화했다(로드맵 Phase 4, docs/CONCEPTS.md 53절).
    ///
    /// `startStepIndex`가 있으면(악보 탭, 74절) 그 스텝의 onsetTime부터 재생한다 — 버튼(항상
    /// nil, 처음부터)과 탭(구체적 인덱스)이 같은 파이프라인을 공유한다. 재생 시작 지점만
    /// `recentVoiceBuffer`를 그 지점부터 잘라서 넣는 걸로 바뀌고, 나머지(정규화/시프트/더블링)는
    /// 그대로다.
    func playHarmonizedVoice(startStepIndex: Int?) {
        // 예전엔 여기서 isScoreRendering을 확인해 악보가 다 그려질 때까지 재생을 통째로 막았다 —
        // 화음 트랙 계산(WORLD, 무거움)이 이 함수 호출 시점에야 시작됐기 때문에, 그 계산이 악보
        // 렌더링(WKWebView JS)과 동시에 CPU를 다퉈 재생 오디오가 끊기는 게 진짜 원인이었다.
        // 이제 그 계산은 녹음 분석이 끝나자마자(precomputeHarmonyTracks) 미리 끝나 있으므로,
        // 이 함수는 "이미 계산된 트랙을 트는" 역할만 남는다 — 더 이상 막을 이유가 없다.
        let isSeek = startStepIndex != nil
        if isPlaybackBusy {
            // 탭으로 인한 재생은 "다른 소리가 재생 중이면 거부" 가드를 우회하고, 대신 지금
            // 재생 중인 소리를 끊고 그 자리에서 새로 시작한다 — 애플 뮤직에서 재생 중에 다른
            // 가사를 탭하면 바로 그리로 이동하는 것과 같은 동작.
            guard isSeek else {
                statusText = "다른 소리가 재생 중이에요 — 끝난 뒤 다시 눌러주세요"
                return
            }
            voiceClipPlayer.stop()
        }
        guard melodySession.suggestedHarmony != nil else {
            statusText = "아직 화음이 없어요 — 먼저 녹음해주세요"
            return
        }
        // 이후 실제 트랙은 스텝마다 자기 화음으로 따로 계산한다(harmonizedTrack) — 여기서는
        // "화음 자체가 있는지"만 가볍게 확인한다.
        guard pitchRatio(toInterval: .bass) != nil,
              pitchRatio(toInterval: .third) != nil,
              pitchRatio(toInterval: .fifth) != nil else {
            statusText = "목표음을 계산하지 못했어요"
            return
        }
        guard !recentVoiceBuffer.isEmpty else {
            statusText = "아직 녹음된 목소리가 없어요 — 먼저 녹음해주세요"
            return
        }
        // 전부 뮤트된 채로 누르면 재생할 게 없다 — 조용히 아무것도 안 하는 대신 이유를 알려준다
        // (버튼을 눌렀는데 반응이 없어 보이는 문제를 막기 위한, 이 파일 전반의 일관된 원칙).
        guard mutedVoices.count < PlaybackVoice.allCases.count else {
            statusText = "재생할 성부가 없어요 — 최소 하나는 켜주세요"
            return
        }

        let startTime: Double
        if let index = startStepIndex, melodySteps.indices.contains(index), let onset = melodySteps[index].onsetTime {
            startTime = onset
        } else {
            startTime = 0
        }
        let startSampleIndex = min(recentVoiceBuffer.count, max(0, Int(startTime * recentVoiceSampleRate)))
        let recorded = Array(recentVoiceBuffer[startSampleIndex...])
        let rate = recentVoiceSampleRate
        let muted = mutedVoices
        let precomputed = precomputedHarmonyTracks
        statusText = "화음 만드는 중…"

        playbackGeneration += 1
        let generation = playbackGeneration

        Task {
            // 예전엔 트랙들을 Swift 배열 단계에서 미리 하나로 합쳐서(AudioGain.mixAndNormalize)
            // 재생했는데, 그러면 성부가 전부 같은 위치(모노)에서만 나와서 서로 뭉개져 들렸다.
            // 이제 각 트랙을 자기 체감 음량으로만 맞추고(합치지 않음) VoiceClipPlayer.playTracks로
            // 넘겨서, 켜진 성부가 실제로 다른 좌우 위치에서 동시에 나오게 한다(docs/CONCEPTS.md 52절).
            let fadeCount = Int(rate * voiceClipFadeDuration)
            func prepare(_ samples: [Float]) -> [Float] {
                AudioGain.applyFadeInOut(AudioGain.normalizeLoudness(samples), fadeSampleCount: fadeCount)
            }

            var tracks: [(samples: [Float], pan: Float)] = []

            if !muted.contains(.melody) {
                tracks.append((prepare(recorded), 0.0)) // 리드 멜로디는 중앙
            }
            // 베이스(한 옥타브 아래) + 3도 + 5도 트랙을 만든다 — 스텝마다 자기 화음 목표로 따로
            // 피치시프트한다(harmonizedTrack, 멜로디가 여러 음일 때 화음이 어긋나던 문제 수정,
            // docs/CONCEPTS.md 81절). 꺼진 성부는 건너뛴다. 보통은 precomputeHarmonyTracks가
            // 이미 다 계산해둔 전체 트랙(startStepIndex: nil 기준, recentVoiceBuffer와 길이가
            // 같음)에서 시작 지점부터 잘라 쓰기만 하면 되고, WORLD 연산을 다시 돌리지 않는다 —
            // 아주 드물게(녹음 끝나자마자 몇백ms 안에 재생을 누른 경우 등) 사전 계산이 아직 안
            // 끝났으면 그때만 예전처럼 그 자리에서 계산한다.
            for (voice, interval) in [(PlaybackVoice.bass, ChordGenerator.Interval.bass),
                                       (.third, .third),
                                       (.fifth, .fifth)] where !muted.contains(voice) {
                // 더블링(성부마다 다른 지연/디튠으로 두께를 주는 것)은 이제 harmonizedTrack
                // 안에서 음(세그먼트) 단위로 이미 적용돼 있다 — 여기서 트랙 전체에 한 번 더
                // 걸면 음이 바뀔 때마다 "직전 음의 지연된 피치"가 새어 들어와 화음이 어긋나
                // 들리던 문제(93절)가 재발한다. 멜로디(원음)는 애초에 더블링 대상이 아니다 —
                // 이미 사용자 자신이 직접 부른 진짜 목소리라 "다른 사람이 한 번 더 부른" 효과가
                // 필요 없고, 오히려 원음이 흔들리면 리드로서의 기준점이 흐려진다.
                let doubled: [Float]
                if let full = precomputed[interval] {
                    doubled = Array(full[min(startSampleIndex, full.count)...])
                } else {
                    doubled = harmonizedTrack(interval: interval, startStepIndex: startStepIndex, startTime: startTime, rate: rate)
                }
                guard !doubled.isEmpty else { continue }
                // interval.gain(바버샵풍 믹스 밸런스, docs/CONCEPTS.md 리서치 섹션 B)은
                // prepare()로 라우드니스를 이미 맞춘 뒤 상대적인 크고 작음만 마지막에 조정한다.
                tracks.append((AudioGain.applyGain(prepare(doubled), factor: interval.gain), interval.pan))
            }

            do {
                isPlayingVoiceClip = true
                // 재생 시작 직후 첫 스텝 전환에서부터 지연 없이 울리도록, 애플이 권장하는 대로
                // 실제 impactOccurred() 호출 전에 미리 준비해둔다.
                downbeatHaptic.prepare()
                upbeatHaptic.prepare()
                // 실제 시작 시각이 아니라 startTime만큼 과거로 앞당긴 시각을 기준점으로 삼는다 —
                // updatePlaybackStepIndex()가 "지금 - 이 시각"으로 경과 시간을 구해서 그대로
                // melodySteps의 onsetTime/duration과 비교하므로, 이렇게 하면 잘라낸 지점부터
                // 재생해도 원본 녹음 타임라인 기준 경과 시간이 계속 정확하게 나온다(한 줄도
                // 안 고치고 재사용 가능).
                voiceClipPlaybackStartedAt = Date().addingTimeInterval(-startTime)
                try voiceClipPlayer.playTracks(tracks, sampleRate: rate) {
                    guard generation == playbackGeneration else { return }
                    isPlayingVoiceClip = false
                    voiceClipPlaybackStartedAt = nil
                    activePlaybackStepIndex = nil
                }
                statusText = "내 목소리로 만든 화음을 재생합니다"
            } catch {
                guard generation == playbackGeneration else { return }
                isPlayingVoiceClip = false
                voiceClipPlaybackStartedAt = nil
                activePlaybackStepIndex = nil
                statusText = "재생 실패: \(error.localizedDescription)"
            }
        }
    }

    /// 악보의 음표를 탭했을 때(`VexFlowScoreView.onSeekToStep`) 호출된다 — 그 지점부터
    /// 재생을 시작하는 얇은 래퍼.
    func seekPlayback(toStep index: Int) {
        playHarmonizedVoice(startStepIndex: index)
    }

    /// 재생헤드 타이머(playheadTimer)가 50ms마다 부른다 — 재생 중이 아니면(voiceClipPlaybackStartedAt이
    /// nil) 즉시 return. 재생 경과 시간이 melodySteps의 어느 스텝 구간(onsetTime~onsetTime+duration)에
    /// 속하는지 찾아서 activePlaybackStepIndex에 반영하면, VexFlowScoreView가 그 인덱스를 받아
    /// 재생헤드 세로선을 옮긴다.
    func updatePlaybackStepIndex() {
        guard let startedAt = voiceClipPlaybackStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        activePlaybackStepIndex = melodySteps.firstIndex { step in
            guard let onset = step.onsetTime, let duration = step.duration else { return false }
            return elapsed >= onset && elapsed < onset + duration
        }
    }

    /// `activePlaybackStepIndex`가 바뀔 때마다(.onChange) 불린다 — 재생이 멈추거나(nil로
    /// 바뀔 때) 시작 직전(nil에서 처음 값이 잡히는 순간 포함)에도 자연스럽게 한 번 울리는
    /// 정도라 굳이 nil을 걸러낼 필요는 없고, index 자체가 nil이면 그냥 아무 것도 안 한다.
    func triggerStepHaptic(for index: Int?) {
        guard let index else { return }
        if downbeatStepIndices.contains(index) {
            downbeatHaptic.impactOccurred()
        } else {
            upbeatHaptic.impactOccurred()
        }
    }

    /// 마디의 첫 박(다운비트) 스텝 인덱스만 모은다 — `RhythmQuantizer.measureBreaks`가 이미
    /// "마디마다 음이 몇 개인지"를 계산해주므로, 각 구간의 시작 인덱스만 누적하면 된다.
    /// `VexFlowScoreView.buildPayload`가 악보를 그릴 때 쓰는 것과 같은 계산을 여기서도 한 번
    /// 더 돌린다 — `activePlaybackStepIndex`가 `melodySteps`(필터링 전) 인덱스를 그대로
    /// 쓰므로, 여기서도 필터링 없이 `melodySteps` 전체 길이 기준으로 맞춘다.
    static func downbeatStepIndices(from melodySteps: [MelodyStep]) -> Set<Int> {
        let quantized = RhythmQuantizer.quantize(durations: melodySteps.map { $0.duration ?? 0.3 })
        let measureBreaks = RhythmQuantizer.measureBreaks(notes: quantized)
        var indices: Set<Int> = []
        var cursor = 0
        for count in measureBreaks {
            if count > 0 { indices.insert(cursor) }
            cursor += count
        }
        return indices
    }
}
