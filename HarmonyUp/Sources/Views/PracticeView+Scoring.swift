import SwiftUI
import SwiftData

/// `PracticeView`의 "따라 부르기 채점" 책임 — 채점 카드 UI, 성부별 채점 시작/중지, 시도
/// 결과를 SwiftData로 저장. 나머지 책임은 `PracticeView.swift`(상태/body),
/// `PracticeView+Layout.swift`(레이아웃), `PracticeView+VoiceHarmony.swift`(화음 재생),
/// `PracticeView+Capture.swift`(녹음/분석)에 있다.
extension PracticeView {
    @ViewBuilder
    var scoringCard: some View {
        if isScoringExpanded {
            HarmonyCard("따라 부르기 채점", systemImage: "target") {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    // "중지"로 채점 시도를 저장한 직후에만 잠깐 보인다 — 예전엔 저장이 조용히
                    // 끝나서 정말 기록됐는지 알 방법이 없었다(크리틱 P3).
                    if let lastSavedInterval {
                        Label("\(lastSavedInterval.koreanLabel) 채점을 저장했어요 — 기록 탭에서 확인해보세요", systemImage: "checkmark.circle.fill")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.pitchGood)
                    }

                    scoringPanel(for: .bass)
                    Divider()
                    scoringPanel(for: .third)
                    Divider()
                    scoringPanel(for: .fifth)

                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { isScoringExpanded = false }
                    } label: {
                        Label("접기", systemImage: "chevron.up")
                    }
                    .harmonyButtonStyle()
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            scoringDisclosureRow
        }
    }

    /// 채점 카드의 접힌 상태 — "내 목소리로 화음" 카드보다 눈에 띄게 가벼운 무게로 보이도록,
    /// HarmonyCard(title3Bold 제목+큰 패딩)를 그대로 안 쓰고 작은 한 줄 디스클로저 행으로
    /// 따로 만들었다. 탭하면 펼쳐지기만 할 뿐 채점을 자동 시작하진 않는다 — 성부별 "채점"
    /// 버튼은 펼친 뒤에도 그대로 남아있다.
    var scoringDisclosureRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isScoringExpanded = true }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "target")
                Text("따라 부르기 채점")
                    .font(Theme.Typography.subheadline)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(Theme.Typography.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .harmonyGlassCard()
        }
        .buttonStyle(.plain)
    }

    /// 성부(베이스/3도/5도) 하나에 대한 채점 패널 — 목표음, 바늘 미터, 시작/중지 버튼을 묶어서 보여준다.
    /// 세 패널이 서로 독립적이라 latestScores[interval]만 각자 참조하고, 다른 쪽 상태에 영향받지 않는다.
    @ViewBuilder
    func scoringPanel(for interval: ChordGenerator.Interval) -> some View {
        let label = interval.koreanLabel
        let isActive = activeScoringInterval == interval
        let target = lockedScoringTargets[interval]
        let score = latestScores[interval]

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 성부 이름을 HistoryView의 정확도 추이 차트와 같은 정체성 색으로 칠해서, 두
                // 화면을 오갈 때도 "이건 3도 얘기구나"를 색으로 먼저 알아챌 수 있게 한다
                // (Theme.intervalColor, 크리틱 "시각 정체성이 약하다" 지적 반영).
                Text(label).font(Theme.Typography.subheadlineBold).foregroundStyle(Theme.intervalColor(for: interval))
                if let target {
                    Text(NoteNameConverter.convert(frequency: target.frequency)?.noteName ?? "?")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    toggleScoring(interval: interval)
                } label: {
                    Label(isActive ? "중지" : "채점", systemImage: isActive ? "stop.fill" : "target")
                }
                .harmonyButtonStyle()
                .disabled(!isActive && melodySession.suggestedHarmony == nil)
            }

            if score == nil && target == nil {
                Text("아직 채점 안 함")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                PitchMeterView(
                    centsOffset: score?.centsOffset,
                    isOnPitch: score?.isOnPitch ?? false,
                    toleranceCents: PitchScorer.onPitchToleranceCents,
                    intervalColor: Theme.intervalColor(for: interval)
                )
                if let score {
                    Text(String(format: "%+.0f cent  %@", score.centsOffset, score.isOnPitch ? "✅ 정확" : "벗어남"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(score.isOnPitch ? Theme.pitchGood : .secondary)
                }
            }
        }
    }

    /// 화음의 3도 또는 5도 음을 채점 목표로 고정한다. 같은 걸 다시 누르면 중지되고,
    /// 채점 중에 다른 쪽을 누르면 멈추지 않고 그쪽 목표로 바로 전환된다 — 3도/5도를
    /// 번갈아 연습할 때 매번 멈췄다 다시 시작할 필요가 없게. 각자의 최근 결과(latestScores)는
    /// 전환하거나 중지해도 지워지지 않고 화면에 남아있는다 — 지워지는 건 "지금 채점 중"인지 여부뿐.
    func toggleScoring(interval: ChordGenerator.Interval) {
        if activeScoringInterval == interval {
            finalizeCurrentAttempt(interval: interval)
            activeScoringInterval = nil
            lastSavedInterval = interval
            return
        }

        // 다른 쪽을 채점하고 있었다면 그 시도부터 기록으로 남긴다.
        if let previous = activeScoringInterval {
            finalizeCurrentAttempt(interval: previous)
        }

        guard let harmony = melodySession.suggestedHarmony,
              let target = harmony.first(where: { $0.interval == interval }) else { return }

        lockedScoringTargets[interval] = target
        activeScoringInterval = interval
        lastSavedInterval = nil // 새 채점을 시작하면 직전 저장 확인 메시지는 지운다
        pitchSmoother.reset() // 이전 채점(또는 다른 음)에서 쓰던 값이 새 채점에 섞여 들어가지 않도록
        onPitchStreak[interval] = 0
        onPitchHapticFired[interval] = false
        scoringSuccessHaptic.prepare() // 실제 발화 전에 미리 준비해서 첫 확정 순간 지연 없이 울리게 한다.

        // "채점하기"를 눌렀는데 마이크가 꺼져 있으면 자동으로 켜준다.
        beginCapturingIfNeeded()
    }

    /// 명세서(v1.0) "3프레임(약 140ms) 유지 확정 시 경쾌한 햅틱" 구현. 허용오차 진입 프레임이
    /// 3번 연속(단음 캡처 확정과 같은 프레임 수 관례)이면 성공 햅틱을 한 번 울리고, 그 연속
    /// 구간 동안은 다시 안 울린다 — 벗어났다가 다시 맞히면 새 연속 구간으로 보고 재발화한다.
    func updateOnPitchStreak(interval: ChordGenerator.Interval, isOnPitch: Bool) {
        guard isOnPitch else {
            onPitchStreak[interval] = 0
            onPitchHapticFired[interval] = false
            return
        }
        let streak = (onPitchStreak[interval] ?? 0) + 1
        onPitchStreak[interval] = streak
        guard streak >= 3, onPitchHapticFired[interval] != true else { return }
        onPitchHapticFired[interval] = true
        scoringSuccessHaptic.notificationOccurred(.success)
    }

    /// 지금까지 쌓인 채점 샘플들을 하나의 요약(PracticeSummary.Aggregate)으로 압축해서
    /// SwiftData에 저장하고, 다음 시도를 위해 그 interval의 샘플 버퍼만 비운다.
    func finalizeCurrentAttempt(interval: ChordGenerator.Interval) {
        defer { scoreSampleBuffers[interval] = [] }

        guard let target = lockedScoringTargets[interval],
              let samples = scoreSampleBuffers[interval],
              let aggregate = PracticeSummary.aggregate(scores: samples) else { return }

        let attempt = PracticeAttempt(
            date: Date(),
            intervalRawValue: interval.storageKey,
            targetNoteName: NoteNameConverter.convert(frequency: target.frequency)?.noteName ?? "?",
            sampleCount: aggregate.sampleCount,
            onPitchRatio: aggregate.onPitchRatio,
            averageAbsCentsOffset: aggregate.averageAbsCentsOffset
        )
        modelContext.insert(attempt)
    }
}
