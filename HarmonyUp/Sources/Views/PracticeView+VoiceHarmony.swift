import SwiftUI

/// `PracticeView`의 "화음" 재생 책임 — 성부별 화음 트랙 계산, 재생, 카라오케 재생헤드
/// 동기화/햅틱까지. 나머지 책임은 `PracticeView.swift`(상태/body),
/// `PracticeView+Layout.swift`(레이아웃), `PracticeView+Scoring.swift`(채점),
/// `PracticeView+Capture.swift`(녹음/분석)에 있다.
///
/// **화음 소리 생성 방식(2026-08-20 변경)**: 92절(WSOLA)부터 WORLD 보코더까지 목소리를
/// 피치시프트해서 화음을 만드는 방식을 계속 다듬어왔지만, "화음이 멜로디랑 따로 들린다"는
/// 실기기 제보가 사라지지 않았다. 사용자가 "화음을 처음 넣었을 때(TonePlayer 합성음,
/// 커밋 `c757f3a`)가 제일 정확했다"며 그 시점의 소리로 되돌려달라고 요청 — 그 시점의 코드
/// 구조 자체는 지금과 완전히 달라(단음 캡처 모드, `ContentView` 단일 파일) 파일 단위로
/// 되돌릴 수 없으므로, 지금 구조 위에서 **화음(베이스/3도/5도)의 소리 생성만**
/// `HarmonyTrackBuilder`(WORLD 피치시프트) 대신 `SynthesizedHarmonyTrackBuilder`
/// (`ToneSynthesizer`로 그때와 같은 파형을 직접 합성)로 바꿨다. 멜로디(원음)는 그대로
/// `recentVoiceBuffer`를 재생하므로 영향 없음. `HarmonyTrackBuilder`/`PitchShifter`/
/// `VoiceDoubler` 자체는 지우지 않고 그대로 뒀다 — 나중에 다시 필요하면 이 파일의 호출부
/// 두 곳(`harmonizedTrack`, `precomputeHarmonyTracks`)만 되돌리면 된다.
extension PracticeView {
    var voiceHarmonyPanel: some View {
        HarmonyCard("내 목소리로 화음", systemImage: "music.mic", iconColor: Theme.voiceAccent) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // 버튼보다 먼저 설명을 둬서, 뭘 누르기 전에 "이게 뭘 하는 버튼인지"부터 읽히게 한다.
                // 화음을 처음 넣었을 때(TonePlayer 합성음)로 되돌린 뒤로는 베이스/3도/5도가
                // 더 이상 목소리를 옮긴 소리가 아니라 합성음이라 문구도 그에 맞게 수정.
                Text(String(format: "방금 녹음한 노래에 베이스/3도/5도 화음을 맞춰 들려줘요 (확보된 목소리: %.1f초)",
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
    /// 실제 조합 로직은 `SynthesizedHarmonyTrackBuilder`(PitchEngine, 순수 함수+유닛테스트)로
    /// 옮겼다 — 이 메서드는 `@State`(melodySteps/recentVoiceBuffer 등)를 그 함수의 명시적
    /// 파라미터로 풀어주는 얇은 래퍼일 뿐이다. 왜 목소리 피치시프트(`HarmonyTrackBuilder`)
    /// 대신 합성음을 쓰는지는 이 파일 상단 문서 참고.
    func harmonizedTrack(interval: ChordGenerator.Interval, startStepIndex: Int?, startTime: Double, rate: Double) -> [Float] {
        SynthesizedHarmonyTrackBuilder.build(
            melodySteps: melodySteps,
            bufferLength: recentVoiceBuffer.count,
            interval: interval,
            startStepIndex: startStepIndex,
            startTime: startTime,
            rate: rate,
            segmentFadeDuration: harmonySegmentFadeDuration
        )
    }

    /// 녹음 분석이 끝나자마자(재생 버튼을 누르기 전에) 성부별 화음 트랙을 미리 다 계산해서
    /// `precomputedHarmonyTracks`에 담아둔다. 예전(WORLD 피치시프트 시절)엔 "재생" 버튼을
    /// 누른 시점에야 이 무거운 연산을 시작해서, 그 계산이 악보 렌더링(WKWebView JS)과 동시에
    /// CPU를 다퉈 재생 오디오가 끊기는 원인이 됐다 — "재생 버튼은 이미 계산돼있는 걸 들어보기
    /// 위한 버튼이어야 하지, 누른 시점에 계산을 시작하는 버튼이면 안 된다"는 지적을 반영해
    /// 계산 시점 자체를 녹음 직후로 앞당겼다. 지금은 `SynthesizedHarmonyTrackBuilder`로
    /// 바뀌어서 연산 자체가 훨씬 가벼워졌지만(단순 사인파 합성), 사전 계산 패턴은 그대로
    /// 유지한다 — 재생 버튼을 누르는 순간 아무 연산도 없이 바로 트는 게 더 단순하고 안전하다.
    func precomputeHarmonyTracks() {
        precomputedHarmonyTracks = [:]
        let rate = recentVoiceSampleRate
        // 실기기 재현: "다시 녹음(연습 화면에서 새로 녹음하기/다시 녹음하기)을 하고 나면 그
        // 다음부터 화음이 뒤로 밀려 들린다" — 원인은 이 Task에 `stopQuickRecording`의
        // `activeAnalysisToken`과 같은 세대 보호가 전혀 없었던 것. 이 Task가 아직 도는
        // 도중(WORLD 연산은 가볍지 않다) 사용자가 재녹음을 끝내버리면: (1) 매 반복마다
        // `self.melodySteps`/`self.recentVoiceBuffer`를 그때그때 실시간으로 읽어서, 성부
        // 일부는 이전 녹음으로 일부는 새 녹음으로 계산되는 상태가 섞일 수 있었고, (2) 설령
        // 안 섞이더라도 이 오래된 Task가 이미 최신(두 번째 녹음의) 계산을 끝낸 새 Task보다
        // 늦게 끝나면 그 낡은 결과로 캐시를 통째로 덮어써버릴 수 있었다. `stopQuickRecording`의
        // 패턴을 그대로 가져와, (a) Task 시작 전에 melodySteps/recentVoiceBuffer를 스냅샷으로
        // 떠서 이 Task 안에서는 항상 "그 순간의 녹음" 하나로만 계산하게 하고, (b) 세대 토큰으로
        // 이 결과가 아직 최신 시도인지 확인한 뒤에만 캐시에 반영한다.
        harmonyPrecomputeGeneration += 1
        let generation = harmonyPrecomputeGeneration
        let stepsSnapshot = melodySteps
        let bufferSnapshot = recentVoiceBuffer
        Task {
            var computed: [ChordGenerator.Interval: [Float]] = [:]
            for interval in ChordGenerator.Interval.allCases {
                computed[interval] = SynthesizedHarmonyTrackBuilder.build(
                    melodySteps: stepsSnapshot,
                    bufferLength: bufferSnapshot.count,
                    interval: interval,
                    startStepIndex: nil,
                    startTime: 0,
                    rate: rate,
                    segmentFadeDuration: harmonySegmentFadeDuration
                )
            }
            guard harmonyPrecomputeGeneration == generation else { return } // 그 사이 재녹음으로 더 최신 시도가 시작됐으면 이 결과는 버린다
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
    /// `recentVoiceBuffer`를 그 지점부터 잘라서 넣는 걸로 바뀌고, 나머지(정규화/믹싱)는 그대로다.
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
            // stop()이 트리거하는 이전 playMixed의 completion은 generation 가드 때문에
            // voiceClipPlaybackStartedAt/activePlaybackStepIndex를 리셋하지 못하고 조용히
            // 무시된다(이 값들을 갱신하는 코드가 그 클로저 안에만 있어서) — 그 결과 새
            // Task가 재생을 다시 시작하기 전까지 짧은 순간 이전 재생의 startedAt이 그대로
            // 남아있고, 그 사이 50ms 재생헤드 타이머(updatePlaybackStepIndex)가 돌면 그
            // 낡은 시각 기준으로 엉뚱한(탭한 음보다 앞선) 스텝을 활성으로 표시한다 — "탭한
            // 음표가 아니라 이전 음표가 눌리는" 현상의 원인. 여기서 즉시 리셋해 그 틈을 없앤다.
            voiceClipPlaybackStartedAt = nil
            activePlaybackStepIndex = nil
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
            // 베이스(한 옥타브 아래) + 3도 + 5도 트랙을 만든다 — 스텝마다 자기 화음 목표
            // 주파수로 따로 합성한다(harmonizedTrack → SynthesizedHarmonyTrackBuilder, 멜로디가
            // 여러 음일 때 화음이 어긋나던 문제 수정, docs/CONCEPTS.md 81절 및 화음 소리 생성
            // 방식 변경은 이 파일 상단 문서 참고). 꺼진 성부는 건너뛴다. 보통은
            // precomputeHarmonyTracks가 이미 다 계산해둔 전체 트랙(startStepIndex: nil 기준,
            // recentVoiceBuffer와 길이가 같음)에서 시작 지점부터 잘라 쓰기만 하면 되고, 다시
            // 합성하지 않는다 — 아주 드물게(녹음 끝나자마자 몇백ms 안에 재생을 누른 경우 등)
            // 사전 계산이 아직 안 끝났으면 그때만 예전처럼 그 자리에서 계산한다.
            for (voice, interval) in [(PlaybackVoice.bass, ChordGenerator.Interval.bass),
                                       (.third, .third),
                                       (.fifth, .fifth)] where !muted.contains(voice) {
                // 합성음이라 더블링(목소리 두께감용 지연+디튠 복사)은 필요 없다 — 톤 자체가
                // 이미 배음이 섞인 파형(ToneSynthesizer)이라 목소리처럼 "얇게" 들리지 않는다.
                let synthesized: [Float]
                if let full = precomputed[interval] {
                    synthesized = Array(full[min(startSampleIndex, full.count)...])
                } else {
                    synthesized = harmonizedTrack(interval: interval, startStepIndex: startStepIndex, startTime: startTime, rate: rate)
                }
                guard !synthesized.isEmpty else { continue }
                // interval.gain(바버샵풍 믹스 밸런스, docs/CONCEPTS.md 리서치 섹션 B)은
                // prepare()로 라우드니스를 이미 맞춘 뒤 상대적인 크고 작음만 마지막에 조정한다.
                tracks.append((AudioGain.applyGain(prepare(synthesized), factor: interval.gain), interval.pan))
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
                // 성부마다 별도 AVAudioPlayerNode에 태워 동시에 play()를 부르던 이전 방식은,
                // 노드가 여러 개라 각자 실제로 소리가 나가기 시작하는 시점이 미세하게 어긋날 수
                // 있었다("화음이 밀린다"는 반복된 실기기 제보의 실제 원인). 재생 직전에 모든
                // 트랙을 pan까지 반영해 하나의 스테레오 버퍼로 미리 합친 뒤(AudioGain.mixToStereo)
                // 단일 노드로 재생하면, 같은 버퍼의 같은 샘플이라 밀릴 여지 자체가 없다.
                let mixed = AudioGain.mixToStereo(tracks: tracks)
                try voiceClipPlayer.playMixed(left: mixed.left, right: mixed.right, sampleRate: rate) {
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
