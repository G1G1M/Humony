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

#ifdef __cplusplus
}
#endif

#endif /* HarmonyUpWorldBridge_h */
