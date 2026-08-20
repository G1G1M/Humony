#ifndef HarmonyUpWorldBridge_h
#define HarmonyUpWorldBridge_h

#ifdef __cplusplus
extern "C" {
#endif

// WORLD(고품질 음성 분석/합성 라이브러리, BSD 라이선스)를 이용해 입력 신호의 피치를
// pitchRatio배로 옮기고, 필요하면 포먼트(스펙트럼 포락선 — 성도 길이가 만드는 음색)도
// formantRatio배로 따로 옮긴다 — WORLD가 신호를 F0(기본주파수)와 스펙트럼 포락선/비주기성으로
// 나눠서 분석하기 때문에, 두 축을 서로 독립적으로 건드릴 수 있다. formantRatio가 1.0(또는
// 유효하지 않은 값)이면 포락선은 원본 그대로 재합성에 쓴다 — 예전처럼 "같은 목소리, 다른
// 음높이"만 필요하면 이 기본값을 쓰면 된다. formantRatio != 1.0이면 포락선을 주파수 축으로
// 워핑해서(1.0보다 크면 포먼트가 위로, 작으면 아래로) 아예 다른 성역의 목소리처럼 들리게 한다
// (docs/CONCEPTS.md 77절).
//
// - input: 모노 오디오, [-1, 1] 범위, double 배열, 길이 length.
// - output: 호출자가 length만큼 미리 할당해둔 버퍼 — 원본과 같은 길이로 채워진다.
// - length가 WORLD 분석에 필요한 최소 길이보다 짧거나 pitchRatio가 유효하지 않으면
//   (예: 0 이하) 원본을 그대로 복사해서 반환한다(피치 변경 없이 — 값이 있는 편이
//   무음보다 안전).
void HarmonyUpWorldPitchShift(const double *input, int length, int sampleRate,
                               double pitchRatio, double formantRatio, double *output);

// 129절 — "화음 음마다 개별 재분석" 대신 "전체 한 번 분석 + F0곡선 재합성" 구조로 가기 위한
// handle 기반 API. 위 HarmonyUpWorldPitchShift가 매번 새로 하던 분석(F0/스펙트럼 포락선/
// 비주기성 추정, 이 파일 위 주석 1~3단계)을 한 번만 해서 이 핸들에 담아두고, 화음 성부마다
// (베이스/3도/5도) F0 곡선만 다르게 바꿔서 여러 번 재합성한다 — 목소리 전체가 하나로 이어진
// 채 처리되므로 세그먼트를 잘라 각각 분석하던 예전 방식과 달리 숨결/떨림이 곡 전체에 걸쳐
// 끊기지 않는다. HarmonyUpWorldPitchShift 자체도 내부적으로 이 API로 구현되어 있어(하위호환
// 유지), 기존 단일 호출부는 그대로 동작한다.
typedef struct HarmonyUpWorldAnalysis HarmonyUpWorldAnalysis;

// input을 한 번 분석해서 핸들을 만든다. 실패(길이가 분석 최소 길이보다 짧음 등)하면 NULL.
// 반환된 핸들은 반드시 HarmonyUpWorldFreeAnalysis로 해제해야 한다.
HarmonyUpWorldAnalysis *HarmonyUpWorldAnalyze(const double *input, int length, int sampleRate);

// 분석된 F0 프레임 개수 — HarmonyUpWorldGetF0로 꺼내거나 HarmonyUpWorldSynthesizeWithF0에
// 넘길 modifiedF0 배열의 길이와 정확히 같다.
int HarmonyUpWorldF0Length(const HarmonyUpWorldAnalysis *analysis);

// 프레임 간격(ms) — 각 F0 프레임이 원본 오디오의 어느 시각(초 = 인덱스 * 값/1000)에
// 해당하는지 계산하는 데 쓴다.
double HarmonyUpWorldFramePeriodMs(const HarmonyUpWorldAnalysis *analysis);

// 분석에 쓰인 원본 오디오 길이(샘플 수) — HarmonyUpWorldSynthesizeWithF0의 output 버퍼를
// 이 길이만큼 미리 할당해야 한다.
int HarmonyUpWorldInputLength(const HarmonyUpWorldAnalysis *analysis);

// 원본(수정 전) F0 곡선을 꺼낸다. outF0는 호출자가 HarmonyUpWorldF0Length(analysis)만큼
// 미리 할당해둔 버퍼.
void HarmonyUpWorldGetF0(const HarmonyUpWorldAnalysis *analysis, double *outF0);

// modifiedF0(길이 = HarmonyUpWorldF0Length(analysis))로 재합성한다 — 스펙트럼 포락선/
// 비주기성은 analysis에 저장된 원본 그대로 재사용하고(분석을 다시 하지 않음), F0만
// modifiedF0로 바꿔치기한다. formantRatio는 HarmonyUpWorldPitchShift와 같은 의미
// (1.0이면 포락선 그대로, 그 외엔 워핑). output은 HarmonyUpWorldInputLength(analysis)
// 길이만큼 호출자가 미리 할당해둔 버퍼.
void HarmonyUpWorldSynthesizeWithF0(const HarmonyUpWorldAnalysis *analysis,
                                     const double *modifiedF0, double formantRatio,
                                     double *output);

// 핸들 해제. NULL을 넘겨도 안전하다.
void HarmonyUpWorldFreeAnalysis(HarmonyUpWorldAnalysis *analysis);

#ifdef __cplusplus
}
#endif

#endif /* HarmonyUpWorldBridge_h */
