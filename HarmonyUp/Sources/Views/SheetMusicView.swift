import SwiftUI

/// 정통 5선보(그랜드 스태프) 형태로 녹음한 멜로디를 보여준다. 앞서 "피치 하이웨이"(색깔
/// 막대, 위치로 음높이를 짐작하는 방식)를 시도했지만 사용자가 "악보 느낌이 안 난다"고
/// 피드백을 줘서, 실제 오선보 표기(줄/칸에 음표를 놓고, 다이어토닉 레터 밖 음은 샵으로
/// 표시, 5선 밖 음은 덧줄)로 다시 만들었다(docs/CONCEPTS.md 56절, 좌표 계산은
/// `StaffGeometry` 참고).
///
/// **박자는 표기하지 않는다** — 이 앱은 박자/템포를 검출하지 않고 초 단위 시작시각/길이만
/// 갖고 있어서, 4분음표/8분음표 같은 정확한 박자 기호는 지금 데이터로는 표현할 수 없다.
/// 대신 시간축을 그대로 가로 위치에 써서(왼쪽에서 오른쪽으로 부른 순서대로) 음의 순서·길이
/// 감각은 유지한다 — "박자가 정확한 악보"는 아니지만 "음높이가 정확한 악보"는 된다.
///
/// **성부 배치**: 멜로디는 높은음자리표, 베이스+3도+5도는 낮은음자리표에 함께 그린다 — 이
/// 앱의 화음 보이싱 규칙상(`ChordGenerator`) 세 화음 성부가 항상 멜로디보다 최소 9반음
/// 아래에 몰려있어서, 실제 합창 악보(SATB)가 소프라노/알토는 높은음자리표, 테너/베이스는
/// 낮은음자리표로 나누는 것과 같은 이유다.
///
/// **성부 on/off**: 범례를 눌러서 성부를 악보에서 숨길 수 있다 — `mutedVoices`는
/// `PracticeView`의 "내 목소리로 화음" 재생과 공유하는 같은 상태라, 여기서 끈 성부는
/// 재생에서도 빠진다(반대도 마찬가지). 로드맵 Phase 6("성부 표시/재생 공유 토글")이 이걸로
/// 자연스럽게 같이 해결됐다.
struct SheetMusicView: View {
    let steps: [MelodyStep]
    @Binding var mutedVoices: Set<PlaybackVoice>

    private let pixelsPerSecond: CGFloat = 90
    private let lineSpacing: CGFloat = 9
    private let staffGap: CGFloat = 44
    private let leadingWidth: CGFloat = 28
    private let topPadding: CGFloat = 26
    private let noteheadWidth: CGFloat = 9
    private let noteheadHeight: CGFloat = 7

    private let melodyColor = Theme.tint

    private func intervalColor(for interval: ChordGenerator.Interval) -> Color {
        switch interval {
        case .bass: return Color(uiColor: .systemGray)
        case .third: return Color(uiColor: .systemTeal)
        case .fifth: return Theme.voiceAccent
        }
    }

    private func color(for voice: PlaybackVoice) -> Color {
        switch voice {
        case .melody: return melodyColor
        case .bass: return intervalColor(for: .bass)
        case .third: return intervalColor(for: .third)
        case .fifth: return intervalColor(for: .fifth)
        }
    }

    private func voice(for interval: ChordGenerator.Interval) -> PlaybackVoice {
        switch interval {
        case .bass: return .bass
        case .third: return .third
        case .fifth: return .fifth
        }
    }

    private func noteName(_ midiNote: Int) -> String {
        NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?"
    }

    private var totalDuration: Double {
        steps.compactMap { step -> Double? in
            guard let onset = step.onsetTime, let duration = step.duration else { return nil }
            return onset + duration
        }.max() ?? 1
    }

    private func x(_ time: Double) -> CGFloat { leadingWidth + CGFloat(time) * pixelsPerSecond }

    var body: some View {
        let trebleBottomY = topPadding + lineSpacing * 4
        let bassBottomY = trebleBottomY + staffGap + lineSpacing * 4
        let treble = StaffGeometry(clef: .treble, lineSpacing: lineSpacing, bottomLineY: trebleBottomY)
        let bass = StaffGeometry(clef: .bass, lineSpacing: lineSpacing, bottomLineY: bassBottomY)
        let contentWidth = x(totalDuration) + 40
        let contentHeight = bassBottomY + lineSpacing * 6 // 낮은 성부 덧줄 여유

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            legend

            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    staffLines(bottomLineY: trebleBottomY, width: contentWidth)
                    staffLines(bottomLineY: bassBottomY, width: contentWidth)
                    clefGlyph("𝄞", topLineY: trebleBottomY - lineSpacing * 4, bottomLineY: trebleBottomY)
                    clefGlyph("𝄢", topLineY: bassBottomY - lineSpacing * 4, bottomLineY: bassBottomY)
                    brace(topY: trebleBottomY - lineSpacing * 4, bottomY: bassBottomY)

                    ForEach(steps) { step in
                        notes(for: step, treble: treble, bass: bass)
                    }
                }
                .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            }
            .frame(height: min(contentHeight + 16, 320))
            .background(
                Color(uiColor: .tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    // MARK: - 범례 + on/off 토글

    private var legend: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(PlaybackVoice.allCases, id: \.self) { voice in
                let isMuted = mutedVoices.contains(voice)
                Button {
                    if isMuted { mutedVoices.remove(voice) } else { mutedVoices.insert(voice) }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color(for: voice)).frame(width: 8, height: 8)
                        Text(voice.koreanLabel)
                    }
                }
                .font(Theme.Typography.caption2)
                .buttonStyle(.bordered)
                .tint(isMuted ? .secondary : color(for: voice))
                .opacity(isMuted ? 0.5 : 1.0)
            }
        }
    }

    // MARK: - 오선/음자리표

    @ViewBuilder
    private func staffLines(bottomLineY: CGFloat, width: CGFloat) -> some View {
        ForEach(0..<5) { i in
            Rectangle()
                .fill(Color(uiColor: .label).opacity(0.5))
                .frame(width: width, height: 1)
                .offset(y: bottomLineY - CGFloat(i) * lineSpacing)
        }
    }

    private func clefGlyph(_ symbol: String, topLineY: CGFloat, bottomLineY: CGFloat) -> some View {
        Text(symbol)
            .font(.system(size: (bottomLineY - topLineY) * 1.3))
            .foregroundStyle(.primary)
            .frame(width: leadingWidth, alignment: .center)
            .position(x: leadingWidth / 2, y: (topLineY + bottomLineY) / 2)
    }

    // 그랜드 스태프 왼쪽을 이어주는 세로선 — 두 오선이 하나의 악보임을 시각적으로 알려준다.
    private func brace(topY: CGFloat, bottomY: CGFloat) -> some View {
        Rectangle()
            .fill(Color(uiColor: .label).opacity(0.6))
            .frame(width: 2, height: bottomY - topY)
            .position(x: 1, y: (topY + bottomY) / 2)
    }

    // MARK: - 음표

    @ViewBuilder
    private func notes(for step: MelodyStep, treble: StaffGeometry, bass: StaffGeometry) -> some View {
        if let onset = step.onsetTime {
            let xPos = x(onset)

            if !mutedVoices.contains(.melody) {
                noteGlyph(midiNote: step.midiNote, label: step.noteName, color: melodyColor, staff: treble, x: xPos)
            }
            if let harmony = step.harmony {
                ForEach(harmony, id: \.interval) { note in
                    if !mutedVoices.contains(voice(for: note.interval)) {
                        noteGlyph(midiNote: note.midiNote, label: noteName(note.midiNote), color: intervalColor(for: note.interval), staff: bass, x: xPos)
                    }
                }
            }
        }
    }

    private func noteGlyph(midiNote: Int, label: String, color: Color, staff: StaffGeometry, x xPos: CGFloat) -> some View {
        let position = staff.position(for: midiNote)
        return ZStack {
            ForEach(position.ledgerLineYs, id: \.self) { ledgerY in
                Rectangle()
                    .fill(Color(uiColor: .label).opacity(0.5))
                    .frame(width: noteheadWidth + 6, height: 1)
                    .position(x: xPos, y: ledgerY)
            }
            if position.needsSharp {
                Text("♯")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .position(x: xPos - noteheadWidth, y: position.y)
            }
            Ellipse()
                .fill(color)
                .frame(width: noteheadWidth, height: noteheadHeight)
                .rotationEffect(.degrees(-20))
                .position(x: xPos, y: position.y)
            // 오선 위치로 음높이를 정확히 알 수 있는 사람에겐 군더더기지만, 이 앱은 악보를
            // 몰라도 되게 설계돼 있어서(핵심 가치) 음이름을 작게 곁들인다 — "실제 악보처럼
            // 보이면서도 읽을 줄 몰라도 무슨 음인지 바로 안다"는 두 요구를 같이 만족시킨다.
            Text(label)
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .position(x: xPos + noteheadWidth + 8, y: position.y)
        }
    }
}
