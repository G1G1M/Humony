---
target: HarmonyUp/Sources/Views/PracticeView.swift (연습 탭)
total_score: 24
max_score: 40
na_heuristics: 
p0_count: 1
p1_count: 3
timestamp: 2026-08-18T12-11-34Z
slug: harmonyup-sources-views-practiceview-swift
---
# HarmonyUp "연습" 탭(PracticeView) 디자인 크리틱

Method: dual-agent (A: design review, general-purpose subagent · B: iOS HIG checklist detector role, general-purpose subagent). Native SwiftUI app — web detect.mjs/browser injection not applicable; Assessment B substituted a literal iOS HIG checklist pass over source. Screenshots: iPad simulator, light+dark, idle state only (post-recording states require live mic input, not reproducible in simulator).

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|---|---|---|
| 1 | Visibility of System Status | 3 | Strong recording/playhead/haptics feedback; scoring lacks live mic-listening cue |
| 2 | Match System/Real World | 2 | "cent"/"3도/5도" jargon surfaced despite Principle 1 |
| 3 | User Control and Freedom | 3 | No explicit stop for harmony playback |
| 4 | Consistency and Standards | 3 | "다시 녹음" means different things per layout |
| 5 | Error Prevention | 3 | Proactive mic-permission check |
| 6 | Recognition Rather Than Recall | 3 | Good toggle/target-note visibility |
| 7 | Flexibility and Efficiency | 2 | No shortcuts past full record→analyze→pick flow |
| 8 | Aesthetic and Minimalist Design | 2 | Sheet music card triples the same info |
| 9 | Error Recovery | 2 | Raw %.5f amplitude leaks into user error copy |
| 10 | Help and Documentation | 1 | No onboarding/tooltips/glossary anywhere |
| **Total** | | **24/40** | **Acceptable** |

## Design Specificity Verdict

Content (own-voice pitch-shift harmony, range-aware clef selection, downbeat/upbeat haptics sharing RhythmQuantizer with notation) is genuinely product-specific. Visual/interaction language (one tint, .bordered/.glass buttons, SF Symbols, vertical card scroll) is close to generic iOS chrome — swap icons/copy and this composition fits many voice-recording utilities. Identity currently lives in the data model, not in composition/motion/color language.

## What's Working

1. ViewThatFits-based unification of 4 voice toggles — Dynamic Type accessibility win that fell out of good component design.
2. Downbeat/upbeat haptics sharing RhythmQuantizer.measureBreaks with the notation — lets a singer feel the beat without looking.
3. Proactive mic-permission handling before hitting a dead end.
4. Consistent design-token usage (HarmonyCard/.harmonyGlassCard()/.harmonyButtonStyle()) and correctly wired Dynamic Type scaling (confirmed by Assessment B).

## Priority Issues

**[P0] Core "hear my own voice harmonized" action gated behind score-rendering finishing**
playHarmonizedVoice refuses to play while isScoreRendering is true. This guard was added this same session (CONCEPTS.md 84절) specifically to fix a real "choppy audio" device bug caused by WKWebView JS render competing with playback for CPU — removing it would reintroduce that bug. The real fix is eliminating the CPU contention itself (lower score-render priority, or pre-render in background right after recording completes) rather than removing the gate — which is also what Assessment A's own suggested fix already pointed at.
Command: /impeccable shape

**[P1] All three post-recording cards (내목소리화음/악보/채점) appear simultaneously with equal visual weight**
Contradicts PRODUCT.md Principle 3 (scoring should not be permanently central) — scoringCard uses identical HarmonyCard chrome/weight as voiceHarmonyPanel. Card order was fixed this session but visual weight was not.
Command: /impeccable distill

**[P1] Sheet music full-screen view breaks dark mode**
SheetMusicFullScreenView.swift:63 sets the entire screen (not just the WKWebView "paper") to Color.white, including title/toggle/caption chrome — inconsistent with every other screen's dark-mode adaptation.
Command: /impeccable polish

**[P1] Raw diagnostic float leaks into user-facing error copy**
"측정된 최대 음량: %.5f" (not #if DEBUG-guarded) shown to end users on recognition failure — meaningless to a non-technical first-time user.
Command: /impeccable clarify

**[P2] "다시 녹음" has different semantics on iPhone vs iPad**
iPhone: full reset. iPad toolbar: preserves context, restarts mic only. Same label, different guarantee.
Command: /impeccable clarify

**[P2] Sub-44pt touch targets + no Reduce Motion support anywhere**
.controlSize(.small) applied near the primary record button risks under-44pt targets; zero accessibilityReduceMotion handling app-wide (card transitions, waveform, pitch meter needle). VoiceOver is out of scope this round per PRODUCT.md, but these two are adjacent, real accessibility gaps.
Command: /impeccable audit

## Persona Red Flags

**Jordan (first-timer, no theory background)**: "베이스/3도/5도"+"cent" surface within seconds with zero onboarding/glossary (Help heuristic 1/4). Hits the raw-float error above with no idea what to change.

**Casey (distracted mobile user)**: QuickRecordView.Phase has no .interrupted case — a phone call mid-recording has no visible recovery path.

**Riley (stress tester)**: 30s-cap auto-stop mutates @State from inside an audio-capture callback closure; main-thread guarantee not verifiable from this file alone — worth device-testing the exact 30s boundary.

## Minor Observations

- voiceToggle duplicated verbatim between PracticeView.swift and SheetMusicFullScreenView.swift
- Two labels use raw .font(.caption) instead of Theme.Typography.caption
- .orange (weaker-interval warning) not promoted to a Theme token like pitchGood/pitchBad
- No positive acknowledgment after a scoring attempt saves
- Sheet music card's "감지된 음: ..." caption repeats info already shown in the staff below it

## Questions to Consider

1. If Principle 3 ("scoring isn't permanently central") should really show up on screen, should the scoring card start collapsed/opt-in rather than auto-expanding?
2. Has the Jordan persona (no theory background) actually been observed hitting "3도/5도/cent" cold, or is "no theory required" still a hypothesis untested against this exact screen?
