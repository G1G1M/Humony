import SwiftUI

/// "내 목소리로 화음" 재생에서 켜고 끌 수 있는 성부 — `ChordGenerator.Interval`(베이스/3도/5도)
/// 3개에 리드 멜로디(원음)를 더한 4가지. 멜로디는 화음 성부가 아니라서 `Interval`에는 없지만,
/// 재생 시 뮤트 대상으로는 다른 성부와 동등하게 다뤄야 해서 별도 enum으로 감쌌다.
enum PlaybackVoice: CaseIterable, Hashable {
    case melody
    case bass
    case third
    case fifth

    var koreanLabel: String {
        switch self {
        case .melody: return "멜로디"
        case .bass: return ChordGenerator.Interval.bass.koreanLabel
        case .third: return ChordGenerator.Interval.third.koreanLabel
        case .fifth: return ChordGenerator.Interval.fifth.koreanLabel
        }
    }

    /// 멜로디(원음)는 화음 성부가 아니라서 대응하는 `Interval`이 없다.
    var interval: ChordGenerator.Interval? {
        switch self {
        case .melody: return nil
        case .bass: return .bass
        case .third: return .third
        case .fifth: return .fifth
        }
    }
}

/// 성부 하나를 켜고 끄는 토글 칩 — `PracticeView`와 `SheetMusicFullScreenView`가 똑같이 쓴다
/// (둘 다 같은 `mutedVoices` `@Binding`을 공유하므로 하나만 있으면 됨 — 예전엔 두 파일에
/// 토씨 하나 안 틀리고 중복 구현돼 있었다, 크리틱 Minor Observations 정리). 눌린 상태(재생에
/// 포함)면 채워진 스타일, 꺼진 상태(뮤트)면 테두리만 있는 스타일로 구분한다. 전부 꺼진 채로
/// 재생 버튼을 누르면 안내 메시지만 뜨고 아무 소리도 안 나므로(playHarmonizedVoice의 guard),
/// 최소 하나는 남겨야 한다는 제약을 UI에서 강제로 막지는 않았다 — 자유롭게 다 꺼봤다가 이유를
/// 읽고 다시 켜는 편이, 어떤 조합이 막혀있는지 미리 계산해서 버튼을 비활성화하는 것보다 단순하다.
struct VoiceToggleChip: View {
    let voice: PlaybackVoice
    @Binding var mutedVoices: Set<PlaybackVoice>

    var body: some View {
        let isMuted = mutedVoices.contains(voice)
        Button {
            if isMuted {
                mutedVoices.remove(voice)
            } else {
                mutedVoices.insert(voice)
            }
        } label: {
            Label(voice.koreanLabel, systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .harmonyButtonStyle()
        .tint(isMuted ? .secondary : Theme.tint)
    }
}
