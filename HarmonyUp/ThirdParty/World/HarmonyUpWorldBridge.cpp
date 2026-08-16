#include "HarmonyUpWorldBridge.h"

#include "world/dio.h"
#include "world/stonemask.h"
#include "world/cheaptrick.h"
#include "world/d4c.h"
#include "world/synthesis.h"

#include <vector>
#include <cstring>

void HarmonyUpWorldPitchShift(const double *input, int length, int sampleRate,
                               double pitchRatio, double *output) {
  if (length <= 0) {
    return;
  }
  if (pitchRatio <= 0.0) {
    std::memcpy(output, input, sizeof(double) * static_cast<size_t>(length));
    return;
  }

  // 1단계: F0(기본주파수) 추정 — WORLD에는 더 정확하지만 훨씬 느린 Harvest도 있는데,
  // 30초짜리 녹음 하나에 5초 넘게 걸려서(성부 3개를 순서대로 만드는 "전체 화음" 버튼은
  // 그 3배) 실측으로 확인 후 Dio+StoneMask 조합으로 바꿨다. Dio는 원래 빠른 대신
  // 다소 거친 초기 추정치를 내는데, StoneMask가 그 추정치를 정제(refine)해서 정확도를
  // Harvest에 준하는 수준까지 끌어올려준다 — 짧은 목소리 클립에서는 이 조합으로도
  // 충분했다(유닛테스트로 피치 정확도 확인).
  DioOption dioOption;
  InitializeDioOption(&dioOption);
  dioOption.frame_period = 5.0;  // ms, WORLD 권장 기본값
  dioOption.f0_floor = 60.0;     // 베이스로 옮긴 음까지 커버하는 낮은 여유
  dioOption.f0_ceil = 1000.0;

  int f0Length = GetSamplesForDIO(sampleRate, length, dioOption.frame_period);
  if (f0Length <= 0) {
    std::memcpy(output, input, sizeof(double) * static_cast<size_t>(length));
    return;
  }

  std::vector<double> temporalPositions(static_cast<size_t>(f0Length));
  std::vector<double> roughF0(static_cast<size_t>(f0Length));
  Dio(input, length, sampleRate, &dioOption, temporalPositions.data(), roughF0.data());

  std::vector<double> f0(static_cast<size_t>(f0Length));
  StoneMask(input, length, sampleRate, temporalPositions.data(), roughF0.data(), f0Length,
            f0.data());

  // 2단계: 스펙트럼 포락선(포먼트) 추정 — 원본 F0 기준으로 분석한다. 이 결과를
  // "건드리지 않고 그대로" 재합성에 다시 쓰는 게 포먼트를 보존하는 핵심이다.
  CheapTrickOption cheapTrickOption;
  InitializeCheapTrickOption(sampleRate, &cheapTrickOption);
  int fftSize = GetFFTSizeForCheapTrick(sampleRate, &cheapTrickOption);
  int spectralSize = fftSize / 2 + 1;

  std::vector<std::vector<double>> spectrogramStorage(
      static_cast<size_t>(f0Length), std::vector<double>(static_cast<size_t>(spectralSize)));
  std::vector<double *> spectrogram(static_cast<size_t>(f0Length));
  for (int i = 0; i < f0Length; ++i) {
    spectrogram[static_cast<size_t>(i)] = spectrogramStorage[static_cast<size_t>(i)].data();
  }
  CheapTrick(input, length, sampleRate, temporalPositions.data(), f0.data(), f0Length,
             &cheapTrickOption, spectrogram.data());

  // 3단계: 비주기성(숨소리/잡음 성분 비율) 추정 — 이것도 원본 그대로 재합성에 쓴다.
  D4COption d4cOption;
  InitializeD4COption(&d4cOption);
  std::vector<std::vector<double>> aperiodicityStorage(
      static_cast<size_t>(f0Length), std::vector<double>(static_cast<size_t>(spectralSize)));
  std::vector<double *> aperiodicity(static_cast<size_t>(f0Length));
  for (int i = 0; i < f0Length; ++i) {
    aperiodicity[static_cast<size_t>(i)] = aperiodicityStorage[static_cast<size_t>(i)].data();
  }
  D4C(input, length, sampleRate, temporalPositions.data(), f0.data(), f0Length, fftSize,
      &d4cOption, aperiodicity.data());

  // 4단계: F0만 pitchRatio배로 옮긴다 — 스펙트로그램(포먼트)/비주기성은 그대로다.
  // 무성음 프레임(f0 == 0)은 옮길 기본주파수 자체가 없으므로 0으로 둔다.
  std::vector<double> shiftedF0(static_cast<size_t>(f0Length));
  for (int i = 0; i < f0Length; ++i) {
    double original = f0[static_cast<size_t>(i)];
    shiftedF0[static_cast<size_t>(i)] = original > 0.0 ? original * pitchRatio : 0.0;
  }

  // 5단계: 옮긴 F0 + 원본 포먼트/비주기성으로 재합성 — "같은 목소리, 다른 음높이".
  Synthesis(shiftedF0.data(), f0Length, spectrogram.data(), aperiodicity.data(), fftSize,
            dioOption.frame_period, sampleRate, length, output);
}
