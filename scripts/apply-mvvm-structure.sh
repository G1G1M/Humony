#!/bin/bash
# HarmonyUp 파일 구조를 junCook(ValleyRisk) MVVM 레이아웃으로 옮긴다.
#
# 배경: 2026-08-24, "Junction2026-team15-junCook의 파일구조(MVVM)를 우리 앱에도 적용" 요청.
# 대응 규약은 docs/ARCHITECTURE.md에 정리해뒀다.
#
# 사용법:
#   scripts/apply-mvvm-structure.sh            # 드라이런 — 무엇이 어디로 갈지만 출력
#   scripts/apply-mvvm-structure.sh --apply    # 실제로 git mv 수행 + project.yml 경로 갱신
#
# 목록은 작성 시점 기준이라, 그 뒤에 생긴 파일은 여기 없다 — 실행 전에 아래 명령으로
# 빠진 게 없는지 대조할 것(139절 TempoEstimator가 실제로 이렇게 누락됐다):
#   comm -23 <(find HarmonyUp/Sources HarmonyUp/Tests -type f \( -name '*.swift' -o -name '*.h' \
#     -o -name '*.plist' \) | sort) <(scripts/apply-mvvm-structure.sh | grep -oE '^  HarmonyUp/[^ ]+' \
#     | sed 's/^  //' | sort) | grep -v ThirdParty
#
# 이 스크립트는 여러 번 돌려도 안전하다(이미 옮겨진 파일은 건너뛴다). 다만 **작업 중인
# 세션이 없을 때** 돌려야 한다 — 다른 에이전트가 같은 파일을 편집하는 중에 경로를 바꾸면
# 그쪽 편집이 엉뚱한 자리에 떨어진다(이 프로젝트에서 실제로 겪은 오염 패턴).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

S=HarmonyUp/Sources
T=HarmonyUp/Tests

# "원본경로 목적지디렉터리" 목록. 목적지는 디렉터리이고, 파일명은 그대로 유지한다.
MOVES=$(cat <<'LIST'
# ── App: 진입점과 번들 리소스 (junCook: App/Source, App/Resource)
HarmonyUp/Sources/HarmonyUpApp.swift                              HarmonyUp/Sources/App/Source
HarmonyUp/Sources/HarmonyUp-Bridging-Header.h                     HarmonyUp/Sources/App/Source
HarmonyUp/Sources/Info.plist                                      HarmonyUp/Sources/App/Source
HarmonyUp/Sources/Resources/Fonts                                 HarmonyUp/Sources/App/Resource
HarmonyUp/Sources/Resources/VexFlowScore                          HarmonyUp/Sources/App/Resource

# ── Core/DesignSystem: 재사용 UI 토큰과 공용 컴포넌트 (junCook: AppColor, AppFont)
HarmonyUp/Sources/DesignSystem/Theme.swift                        HarmonyUp/Sources/Core/DesignSystem
HarmonyUp/Sources/DesignSystem/WaveformView.swift                 HarmonyUp/Sources/Core/DesignSystem
HarmonyUp/Sources/Views/LoadingIndicators.swift                   HarmonyUp/Sources/Core/DesignSystem
HarmonyUp/Sources/PitchMeterView.swift                            HarmonyUp/Sources/Core/DesignSystem

# ── Core/Local: 기기 I/O 래퍼 (junCook: LocationProvider)
HarmonyUp/Sources/PitchEngine/AudioCapture.swift                  HarmonyUp/Sources/Core/Local
HarmonyUp/Sources/PitchEngine/RecordingPlayer.swift               HarmonyUp/Sources/Core/Local
HarmonyUp/Sources/PitchEngine/TonePlayer.swift                    HarmonyUp/Sources/Core/Local

# ── Core/Util: 전 계층이 쓰는 변환 (Int.mod 확장도 이 파일에 있다)
HarmonyUp/Sources/PitchEngine/NoteNameConverter.swift             HarmonyUp/Sources/Core/Util

# ── Data/DB: 영속 모델 (junCook: AppStorageKey)
HarmonyUp/Sources/PracticeAttempt.swift                           HarmonyUp/Sources/Data/DB
HarmonyUp/Sources/PracticeSession.swift                           HarmonyUp/Sources/Data/DB

# ── Domain/Pitch: 음높이 검출과 판정
HarmonyUp/Sources/PitchEngine/YINPitchDetector.swift              HarmonyUp/Sources/Domain/Pitch
HarmonyUp/Sources/PitchEngine/PitchSmoother.swift                 HarmonyUp/Sources/Domain/Pitch
HarmonyUp/Sources/PitchEngine/VoiceActivityDetector.swift         HarmonyUp/Sources/Domain/Pitch
HarmonyUp/Sources/PitchEngine/PitchScorer.swift                   HarmonyUp/Sources/Domain/Pitch

# ── Domain/Melody: 채보(녹음 → 음표 시퀀스)
HarmonyUp/Sources/PitchEngine/MelodySegmenter.swift               HarmonyUp/Sources/Domain/Melody
HarmonyUp/Sources/PitchEngine/MelodySession.swift                 HarmonyUp/Sources/Domain/Melody
HarmonyUp/Sources/PitchEngine/RecordingAnalyzer.swift             HarmonyUp/Sources/Domain/Melody
HarmonyUp/Sources/PitchEngine/RhythmQuantizer.swift               HarmonyUp/Sources/Domain/Melody
HarmonyUp/Sources/PitchEngine/TempoEstimator.swift                HarmonyUp/Sources/Domain/Melody
HarmonyUp/Sources/PitchEngine/KeyDetector.swift                  HarmonyUp/Sources/Domain/Melody
HarmonyUp/Sources/Views/MelodyStep.swift                          HarmonyUp/Sources/Domain/Melody

# ── Domain/Harmony: 화음 생성과 오디오 합성
HarmonyUp/Sources/PitchEngine/ChordGenerator.swift                HarmonyUp/Sources/Domain/Harmony
HarmonyUp/Sources/PitchEngine/VoiceHarmonyTrackBuilder.swift      HarmonyUp/Sources/Domain/Harmony
HarmonyUp/Sources/PitchEngine/SynthesizedHarmonyTrackBuilder.swift HarmonyUp/Sources/Domain/Harmony
HarmonyUp/Sources/PitchEngine/ToneSynthesizer.swift               HarmonyUp/Sources/Domain/Harmony
HarmonyUp/Sources/PitchEngine/PitchShifter.swift                  HarmonyUp/Sources/Domain/Harmony
HarmonyUp/Sources/PitchEngine/PitchShifterWorld.swift             HarmonyUp/Sources/Domain/Harmony
HarmonyUp/Sources/PitchEngine/PitchShifterWorldAnalysis.swift     HarmonyUp/Sources/Domain/Harmony
HarmonyUp/Sources/PitchEngine/AudioGain.swift                     HarmonyUp/Sources/Domain/Harmony

# ── Domain/Scoring: 채점 엔진
HarmonyUp/Sources/PitchEngine/HarmonyPracticeScorer.swift         HarmonyUp/Sources/Domain/Scoring
HarmonyUp/Sources/PitchEngine/PracticeSummary.swift               HarmonyUp/Sources/Domain/Scoring

# ── Features/Main
HarmonyUp/Sources/Views/RootTabView.swift                         HarmonyUp/Sources/Features/Main/View

# ── Features/Practice (junCook: Features/Dashboard의 Model+View 구성과 같은 모양)
HarmonyUp/Sources/Views/VexFlowScorePayload.swift                 HarmonyUp/Sources/Features/Practice/Model
HarmonyUp/Sources/Views/PracticeView.swift                        HarmonyUp/Sources/Features/Practice/View
HarmonyUp/Sources/Views/PracticeView+Layout.swift                 HarmonyUp/Sources/Features/Practice/View
HarmonyUp/Sources/Views/PracticeView+Capture.swift                HarmonyUp/Sources/Features/Practice/View
HarmonyUp/Sources/Views/PracticeView+Scoring.swift                HarmonyUp/Sources/Features/Practice/View
HarmonyUp/Sources/Views/QuickRecordView.swift                     HarmonyUp/Sources/Features/Practice/View
HarmonyUp/Sources/Views/VexFlowScoreView.swift                    HarmonyUp/Sources/Features/Practice/View
HarmonyUp/Sources/Views/SheetMusicFullScreenView.swift            HarmonyUp/Sources/Features/Practice/View

# ── Features/History
HarmonyUp/Sources/PitchEngine/PracticeStatistics.swift            HarmonyUp/Sources/Features/History/Model
HarmonyUp/Sources/Views/HistoryView.swift                         HarmonyUp/Sources/Features/History/View
HarmonyUp/Sources/Views/SessionDetailView.swift                   HarmonyUp/Sources/Features/History/View

# ── 테스트: 소스 구조를 그대로 반영
HarmonyUp/Tests/PitchEngineTests/NoteNameConverterTests.swift            HarmonyUp/Tests/Core/Util
HarmonyUp/Tests/PitchEngineTests/YINPitchDetectorTests.swift             HarmonyUp/Tests/Domain/Pitch
HarmonyUp/Tests/PitchEngineTests/PitchSmootherTests.swift                HarmonyUp/Tests/Domain/Pitch
HarmonyUp/Tests/PitchEngineTests/VoiceActivityDetectorTests.swift        HarmonyUp/Tests/Domain/Pitch
HarmonyUp/Tests/PitchEngineTests/PitchScorerTests.swift                  HarmonyUp/Tests/Domain/Pitch
HarmonyUp/Tests/PitchEngineTests/MelodySegmenterTests.swift              HarmonyUp/Tests/Domain/Melody
HarmonyUp/Tests/PitchEngineTests/MelodySessionTests.swift                HarmonyUp/Tests/Domain/Melody
HarmonyUp/Tests/PitchEngineTests/RecordingAnalyzerTests.swift            HarmonyUp/Tests/Domain/Melody
HarmonyUp/Tests/PitchEngineTests/RhythmQuantizerTests.swift              HarmonyUp/Tests/Domain/Melody
HarmonyUp/Tests/PitchEngineTests/TempoEstimatorTests.swift               HarmonyUp/Tests/Domain/Melody
HarmonyUp/Tests/PitchEngineTests/KeyDetectorTests.swift                  HarmonyUp/Tests/Domain/Melody
HarmonyUp/Tests/PitchEngineTests/ChordGeneratorTests.swift               HarmonyUp/Tests/Domain/Harmony
HarmonyUp/Tests/PitchEngineTests/VoiceHarmonyTrackBuilderTests.swift     HarmonyUp/Tests/Domain/Harmony
HarmonyUp/Tests/PitchEngineTests/SynthesizedHarmonyTrackBuilderTests.swift HarmonyUp/Tests/Domain/Harmony
HarmonyUp/Tests/PitchEngineTests/ToneSynthesizerTests.swift              HarmonyUp/Tests/Domain/Harmony
HarmonyUp/Tests/PitchEngineTests/PitchShifterTests.swift                 HarmonyUp/Tests/Domain/Harmony
HarmonyUp/Tests/PitchEngineTests/PitchShifterWorldTests.swift            HarmonyUp/Tests/Domain/Harmony
HarmonyUp/Tests/PitchEngineTests/PitchShifterWorldAnalysisTests.swift    HarmonyUp/Tests/Domain/Harmony
HarmonyUp/Tests/PitchEngineTests/AudioGainTests.swift                    HarmonyUp/Tests/Domain/Harmony
HarmonyUp/Tests/PitchEngineTests/HarmonyPracticeScorerTests.swift        HarmonyUp/Tests/Domain/Scoring
HarmonyUp/Tests/PitchEngineTests/PracticeSummaryTests.swift              HarmonyUp/Tests/Domain/Scoring
HarmonyUp/Tests/PitchEngineTests/VexFlowScorePayloadTests.swift          HarmonyUp/Tests/Features/Practice
HarmonyUp/Tests/PitchEngineTests/PracticeStatisticsTests.swift           HarmonyUp/Tests/Features/History
HarmonyUp/Tests/PitchEngineTests/PracticeSessionTests.swift             HarmonyUp/Tests/Features/History
LIST
)

moved=0; skipped=0; missing=0
while read -r src dest; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    name=$(basename "$src")
    if [[ ! -e "$src" ]]; then
        if [[ -e "$dest/$name" ]]; then
            echo "  이미 이동됨: $dest/$name"; skipped=$((skipped+1))
        else
            echo "  ⚠ 원본 없음: $src"; missing=$((missing+1))
        fi
        continue
    fi
    echo "  $src  ->  $dest/$name"
    if (( APPLY )); then
        mkdir -p "$dest"
        # 추적 중인 파일은 git mv로 옮겨 이름 변경 이력이 남게 한다. 아직 커밋되지
        # 않은(untracked) 파일은 git이 모르므로 평범한 mv를 쓴다.
        if git ls-files --error-unmatch "$src" >/dev/null 2>&1; then
            git mv "$src" "$dest/$name" || exit 1
        else
            mv "$src" "$dest/$name" || exit 1
        fi
    fi
    moved=$((moved+1))
done <<< "$MOVES"

echo
echo "이동 대상 ${moved}개, 이미 이동됨 ${skipped}개, 원본 없음 ${missing}개"

# 이 목록을 쓴 뒤에 새로 생긴 파일은 갈 곳이 정해져 있지 않다 — 조용히 옛 자리에
# 남겨두면 구조가 반쪽이 되므로, 남은 옛 디렉터리에 뭐가 있는지 반드시 보고한다.
if (( APPLY )); then
leftovers=$(find "$S/PitchEngine" "$S/Views" "$S/DesignSystem" "$S/Resources" "$T/PitchEngineTests" \
              -type f 2>/dev/null | sort)
if [[ -n "$leftovers" ]]; then
    echo
    echo "⚠ 아직 옛 자리에 남은 파일 — 목록에 없는 새 파일일 수 있으니 갈 곳을 정해주세요:"
    echo "$leftovers" | sed 's/^/    /'
fi
fi

if (( APPLY )); then
    # project.yml이 절대 경로로 가리키는 두 파일의 위치가 바뀐다.
    sed -i '' \
        -e 's#SWIFT_OBJC_BRIDGING_HEADER: HarmonyUp/Sources/HarmonyUp-Bridging-Header.h#SWIFT_OBJC_BRIDGING_HEADER: HarmonyUp/Sources/App/Source/HarmonyUp-Bridging-Header.h#' \
        -e 's#path: HarmonyUp/Sources/Info.plist#path: HarmonyUp/Sources/App/Source/Info.plist#' \
        project.yml
    # 빈 껍데기 디렉터리 정리
    find "$S" "$T" -type d -empty -delete
    echo "project.yml 경로 갱신 완료 — 이제 'xcodegen generate' 후 테스트를 돌리세요."
else
    echo "드라이런입니다. 실제로 옮기려면 --apply 를 붙이세요."
fi
