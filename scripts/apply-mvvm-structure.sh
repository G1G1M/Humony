#!/bin/bash
# Humony 파일 구조를 junCook(ValleyRisk) MVVM 레이아웃으로 옮긴다.
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
#   comm -23 <(find Humony/Sources Humony/Tests -type f \( -name '*.swift' -o -name '*.h' \
#     -o -name '*.plist' \) | sort) <(scripts/apply-mvvm-structure.sh | grep -oE '^  Humony/[^ ]+' \
#     | sed 's/^  //' | sort) | grep -v ThirdParty
#
# 이 스크립트는 여러 번 돌려도 안전하다(이미 옮겨진 파일은 건너뛴다). 다만 **작업 중인
# 세션이 없을 때** 돌려야 한다 — 다른 에이전트가 같은 파일을 편집하는 중에 경로를 바꾸면
# 그쪽 편집이 엉뚱한 자리에 떨어진다(이 프로젝트에서 실제로 겪은 오염 패턴).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

S=Humony/Sources
T=Humony/Tests

# "원본경로 목적지디렉터리" 목록. 목적지는 디렉터리이고, 파일명은 그대로 유지한다.
MOVES=$(cat <<'LIST'
# ── App: 진입점과 번들 리소스 (junCook: App/Source, App/Resource)
Humony/Sources/HumonyApp.swift                              Humony/Sources/App/Source
Humony/Sources/Humony-Bridging-Header.h                     Humony/Sources/App/Source
Humony/Sources/Info.plist                                      Humony/Sources/App/Source
Humony/Sources/Resources/Fonts                                 Humony/Sources/App/Resource
Humony/Sources/Resources/VexFlowScore                          Humony/Sources/App/Resource

# ── Core/DesignSystem: 재사용 UI 토큰과 공용 컴포넌트 (junCook: AppColor, AppFont)
Humony/Sources/DesignSystem/Theme.swift                        Humony/Sources/Core/DesignSystem
Humony/Sources/DesignSystem/WaveformView.swift                 Humony/Sources/Core/DesignSystem
Humony/Sources/Views/LoadingIndicators.swift                   Humony/Sources/Core/DesignSystem
Humony/Sources/PitchMeterView.swift                            Humony/Sources/Core/DesignSystem

# ── Core/Local: 기기 I/O 래퍼 (junCook: LocationProvider)
Humony/Sources/PitchEngine/AudioCapture.swift                  Humony/Sources/Core/Local
Humony/Sources/PitchEngine/RecordingPlayer.swift               Humony/Sources/Core/Local
Humony/Sources/PitchEngine/TonePlayer.swift                    Humony/Sources/Core/Local

# ── Core/Util: 전 계층이 쓰는 변환 (Int.mod 확장도 이 파일에 있다)
Humony/Sources/PitchEngine/NoteNameConverter.swift             Humony/Sources/Core/Util

# ── Data/DB: 영속 모델 (junCook: AppStorageKey)
Humony/Sources/PracticeAttempt.swift                           Humony/Sources/Data/DB
Humony/Sources/PracticeSession.swift                           Humony/Sources/Data/DB

# ── Domain/Pitch: 음높이 검출과 판정
Humony/Sources/PitchEngine/YINPitchDetector.swift              Humony/Sources/Domain/Pitch
Humony/Sources/PitchEngine/PitchSmoother.swift                 Humony/Sources/Domain/Pitch
Humony/Sources/PitchEngine/VoiceActivityDetector.swift         Humony/Sources/Domain/Pitch
Humony/Sources/PitchEngine/PitchScorer.swift                   Humony/Sources/Domain/Pitch

# ── Domain/Melody: 채보(녹음 → 음표 시퀀스)
Humony/Sources/PitchEngine/MelodySegmenter.swift               Humony/Sources/Domain/Melody
Humony/Sources/PitchEngine/MelodySession.swift                 Humony/Sources/Domain/Melody
Humony/Sources/PitchEngine/RecordingAnalyzer.swift             Humony/Sources/Domain/Melody
Humony/Sources/PitchEngine/RhythmQuantizer.swift               Humony/Sources/Domain/Melody
Humony/Sources/PitchEngine/TempoEstimator.swift                Humony/Sources/Domain/Melody
Humony/Sources/PitchEngine/KeyDetector.swift                  Humony/Sources/Domain/Melody
Humony/Sources/Views/MelodyStep.swift                          Humony/Sources/Domain/Melody

# ── Domain/Harmony: 화음 생성과 오디오 합성
Humony/Sources/PitchEngine/ChordGenerator.swift                Humony/Sources/Domain/Harmony
Humony/Sources/PitchEngine/VoiceHarmonyTrackBuilder.swift      Humony/Sources/Domain/Harmony
Humony/Sources/PitchEngine/SynthesizedHarmonyTrackBuilder.swift Humony/Sources/Domain/Harmony
Humony/Sources/PitchEngine/ToneSynthesizer.swift               Humony/Sources/Domain/Harmony
Humony/Sources/PitchEngine/PitchShifter.swift                  Humony/Sources/Domain/Harmony
Humony/Sources/PitchEngine/PitchShifterWorld.swift             Humony/Sources/Domain/Harmony
Humony/Sources/PitchEngine/PitchShifterWorldAnalysis.swift     Humony/Sources/Domain/Harmony
Humony/Sources/PitchEngine/AudioGain.swift                     Humony/Sources/Domain/Harmony

# ── Domain/Scoring: 채점 엔진
Humony/Sources/PitchEngine/HarmonyPracticeScorer.swift         Humony/Sources/Domain/Scoring
Humony/Sources/PitchEngine/PracticeSummary.swift               Humony/Sources/Domain/Scoring

# ── Features/Main
Humony/Sources/Views/RootTabView.swift                         Humony/Sources/Features/Main/View

# ── Features/Practice (junCook: Features/Dashboard의 Model+View 구성과 같은 모양)
Humony/Sources/Views/VexFlowScorePayload.swift                 Humony/Sources/Features/Practice/Model
Humony/Sources/Views/PracticeView.swift                        Humony/Sources/Features/Practice/View
Humony/Sources/Views/PracticeView+Layout.swift                 Humony/Sources/Features/Practice/View
Humony/Sources/Views/PracticeView+Capture.swift                Humony/Sources/Features/Practice/View
Humony/Sources/Views/PracticeView+Scoring.swift                Humony/Sources/Features/Practice/View
Humony/Sources/Views/QuickRecordView.swift                     Humony/Sources/Features/Practice/View
Humony/Sources/Views/VexFlowScoreView.swift                    Humony/Sources/Features/Practice/View
Humony/Sources/Views/SheetMusicFullScreenView.swift            Humony/Sources/Features/Practice/View

# ── Features/History
Humony/Sources/PitchEngine/PracticeStatistics.swift            Humony/Sources/Features/History/Model
Humony/Sources/Views/HistoryView.swift                         Humony/Sources/Features/History/View
Humony/Sources/Views/SessionDetailView.swift                   Humony/Sources/Features/History/View

# ── 테스트: 소스 구조를 그대로 반영
Humony/Tests/PitchEngineTests/NoteNameConverterTests.swift            Humony/Tests/Core/Util
Humony/Tests/PitchEngineTests/YINPitchDetectorTests.swift             Humony/Tests/Domain/Pitch
Humony/Tests/PitchEngineTests/PitchSmootherTests.swift                Humony/Tests/Domain/Pitch
Humony/Tests/PitchEngineTests/VoiceActivityDetectorTests.swift        Humony/Tests/Domain/Pitch
Humony/Tests/PitchEngineTests/PitchScorerTests.swift                  Humony/Tests/Domain/Pitch
Humony/Tests/PitchEngineTests/MelodySegmenterTests.swift              Humony/Tests/Domain/Melody
Humony/Tests/PitchEngineTests/MelodySessionTests.swift                Humony/Tests/Domain/Melody
Humony/Tests/PitchEngineTests/RecordingAnalyzerTests.swift            Humony/Tests/Domain/Melody
Humony/Tests/PitchEngineTests/RhythmQuantizerTests.swift              Humony/Tests/Domain/Melody
Humony/Tests/PitchEngineTests/TempoEstimatorTests.swift               Humony/Tests/Domain/Melody
Humony/Tests/PitchEngineTests/KeyDetectorTests.swift                  Humony/Tests/Domain/Melody
Humony/Tests/PitchEngineTests/ChordGeneratorTests.swift               Humony/Tests/Domain/Harmony
Humony/Tests/PitchEngineTests/VoiceHarmonyTrackBuilderTests.swift     Humony/Tests/Domain/Harmony
Humony/Tests/PitchEngineTests/SynthesizedHarmonyTrackBuilderTests.swift Humony/Tests/Domain/Harmony
Humony/Tests/PitchEngineTests/ToneSynthesizerTests.swift              Humony/Tests/Domain/Harmony
Humony/Tests/PitchEngineTests/PitchShifterTests.swift                 Humony/Tests/Domain/Harmony
Humony/Tests/PitchEngineTests/PitchShifterWorldTests.swift            Humony/Tests/Domain/Harmony
Humony/Tests/PitchEngineTests/PitchShifterWorldAnalysisTests.swift    Humony/Tests/Domain/Harmony
Humony/Tests/PitchEngineTests/AudioGainTests.swift                    Humony/Tests/Domain/Harmony
Humony/Tests/PitchEngineTests/HarmonyPracticeScorerTests.swift        Humony/Tests/Domain/Scoring
Humony/Tests/PitchEngineTests/PracticeSummaryTests.swift              Humony/Tests/Domain/Scoring
Humony/Tests/PitchEngineTests/VexFlowScorePayloadTests.swift          Humony/Tests/Features/Practice
Humony/Tests/PitchEngineTests/PracticeStatisticsTests.swift           Humony/Tests/Features/History
Humony/Tests/PitchEngineTests/PracticeSessionTests.swift             Humony/Tests/Features/History
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
        -e 's#SWIFT_OBJC_BRIDGING_HEADER: Humony/Sources/Humony-Bridging-Header.h#SWIFT_OBJC_BRIDGING_HEADER: Humony/Sources/App/Source/Humony-Bridging-Header.h#' \
        -e 's#path: Humony/Sources/Info.plist#path: Humony/Sources/App/Source/Info.plist#' \
        project.yml
    # 빈 껍데기 디렉터리 정리
    find "$S" "$T" -type d -empty -delete
    echo "project.yml 경로 갱신 완료 — 이제 'xcodegen generate' 후 테스트를 돌리세요."
else
    echo "드라이런입니다. 실제로 옮기려면 --apply 를 붙이세요."
fi
