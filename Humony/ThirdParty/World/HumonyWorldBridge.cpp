#include "HumonyWorldBridge.h"

#include "world/dio.h"
#include "world/stonemask.h"
#include "world/cheaptrick.h"
#include "world/d4c.h"
#include "world/synthesis.h"
#include "world/constantnumbers.h"

#include <vector>
#include <cstring>

// 129절 — HumonyWorldPitchShift가 예전에 한 함수 안에서 순서대로 하던 "분석(F0/스펙트럼
// 포락선/비주기성 추정) -> 재합성"을 이 struct에 분석 결과를 담아 두 단계로 쪼갠다. 헤더에는
// 전방선언만 노출해서(정의는 이 파일 안에만 있음) Swift/C 쪽에서는 완전한 불투명 포인터로만
// 다룬다 — CoreFoundation의 CFTypeRef 같은 패턴과 동일.
struct HumonyWorldAnalysis {
  int length = 0;
  int sampleRate = 0;
  double framePeriod = 0.0;
  int f0Length = 0;
  int fftSize = 0;
  int spectralSize = 0;
  std::vector<double> f0;
  std::vector<std::vector<double>> spectrogram;
  std::vector<std::vector<double>> aperiodicity;
};

HumonyWorldAnalysis *HumonyWorldAnalyze(const double *input, int length, int sampleRate,
                                               double d4cThreshold) {
  if (length <= 0) {
    return nullptr;
  }

  // 1단계: F0(기본주파수) 추정 — WORLD에는 더 정확하지만 훨씬 느린 Harvest도 있는데,
  // 30초짜리 녹음 하나에 5초 넘게 걸려서 실측으로 확인 후 Dio+StoneMask 조합으로 바꿨다.
  // Dio는 원래 빠른 대신 다소 거친 초기 추정치를 내는데, StoneMask가 그 추정치를 정제
  // (refine)해서 정확도를 Harvest에 준하는 수준까지 끌어올려준다.
  DioOption dioOption;
  InitializeDioOption(&dioOption);
  dioOption.frame_period = 5.0;  // ms, WORLD 권장 기본값
  dioOption.f0_floor = 60.0;     // 베이스로 옮긴 음까지 커버하는 낮은 여유
  dioOption.f0_ceil = 1000.0;

  int f0Length = GetSamplesForDIO(sampleRate, length, dioOption.frame_period);
  if (f0Length <= 0) {
    return nullptr;
  }

  std::vector<double> temporalPositions(static_cast<size_t>(f0Length));
  std::vector<double> roughF0(static_cast<size_t>(f0Length));
  Dio(input, length, sampleRate, &dioOption, temporalPositions.data(), roughF0.data());

  auto *analysis = new HumonyWorldAnalysis();
  analysis->length = length;
  analysis->sampleRate = sampleRate;
  analysis->framePeriod = dioOption.frame_period;
  analysis->f0Length = f0Length;
  analysis->f0.resize(static_cast<size_t>(f0Length));
  StoneMask(input, length, sampleRate, temporalPositions.data(), roughF0.data(), f0Length,
            analysis->f0.data());

  // 2단계: 스펙트럼 포락선(포먼트) 추정 — 원본 F0 기준으로 분석한다. 이 결과를
  // "건드리지 않고 그대로" 재합성에 다시 쓰는 게 포먼트를 보존하는 핵심이다.
  CheapTrickOption cheapTrickOption;
  InitializeCheapTrickOption(sampleRate, &cheapTrickOption);
  int fftSize = GetFFTSizeForCheapTrick(sampleRate, &cheapTrickOption);
  int spectralSize = fftSize / 2 + 1;
  analysis->fftSize = fftSize;
  analysis->spectralSize = spectralSize;

  analysis->spectrogram.assign(static_cast<size_t>(f0Length),
                                std::vector<double>(static_cast<size_t>(spectralSize)));
  std::vector<double *> spectrogram(static_cast<size_t>(f0Length));
  for (int i = 0; i < f0Length; ++i) {
    spectrogram[static_cast<size_t>(i)] = analysis->spectrogram[static_cast<size_t>(i)].data();
  }
  CheapTrick(input, length, sampleRate, temporalPositions.data(), analysis->f0.data(), f0Length,
             &cheapTrickOption, spectrogram.data());

  // 3단계: 비주기성(숨소리/잡음 성분 비율) 추정 — 이것도 원본 그대로 재합성에 쓴다.
  // threshold를 호출자가 넘긴 값으로 덮어써서 "D4C Love Train" 지름길(132절 헤더 주석 참고)
  // 발동 빈도를 조절할 수 있게 한다 — InitializeD4COption의 기본값(world::kThreshold)에서
  // 시작해 덮어쓰는 구조라, 기존 호출부처럼 기본값을 그대로 쓰고 싶으면 d4cThreshold에
  // world::kThreshold를 넘기면 된다.
  D4COption d4cOption;
  InitializeD4COption(&d4cOption);
  d4cOption.threshold = d4cThreshold;
  analysis->aperiodicity.assign(static_cast<size_t>(f0Length),
                                 std::vector<double>(static_cast<size_t>(spectralSize)));
  std::vector<double *> aperiodicity(static_cast<size_t>(f0Length));
  for (int i = 0; i < f0Length; ++i) {
    aperiodicity[static_cast<size_t>(i)] = analysis->aperiodicity[static_cast<size_t>(i)].data();
  }
  D4C(input, length, sampleRate, temporalPositions.data(), analysis->f0.data(), f0Length, fftSize,
      &d4cOption, aperiodicity.data());

  return analysis;
}

int HumonyWorldF0Length(const HumonyWorldAnalysis *analysis) {
  return analysis ? analysis->f0Length : 0;
}

double HumonyWorldFramePeriodMs(const HumonyWorldAnalysis *analysis) {
  return analysis ? analysis->framePeriod : 0.0;
}

int HumonyWorldInputLength(const HumonyWorldAnalysis *analysis) {
  return analysis ? analysis->length : 0;
}

void HumonyWorldGetF0(const HumonyWorldAnalysis *analysis, double *outF0) {
  if (!analysis) {
    return;
  }
  std::memcpy(outF0, analysis->f0.data(), sizeof(double) * analysis->f0.size());
}

void HumonyWorldSynthesizeWithF0(const HumonyWorldAnalysis *analysis,
                                     const double *modifiedF0, double formantRatio,
                                     double *output) {
  if (!analysis) {
    return;
  }
  const int f0Length = analysis->f0Length;
  const int spectralSize = analysis->spectralSize;

  std::vector<const double *> spectrogram(static_cast<size_t>(f0Length));
  std::vector<const double *> aperiodicity(static_cast<size_t>(f0Length));
  for (int i = 0; i < f0Length; ++i) {
    spectrogram[static_cast<size_t>(i)] = analysis->spectrogram[static_cast<size_t>(i)].data();
    aperiodicity[static_cast<size_t>(i)] = analysis->aperiodicity[static_cast<size_t>(i)].data();
  }

  // formantRatio가 1.0이 아니면 스펙트럼 포락선(포먼트)을 주파수 축으로 워핑한다 — F0(피치)
  // 축과 완전히 분리된 별개의 축이라, 여기서 포먼트를 옮겨도 modifiedF0로 정한 피치는 그대로
  // 유지된다. 출력 빈 k의 값을 원본의 k/formantRatio 위치에서 선형보간해 가져온다
  // (formantRatio > 1이면 포먼트가 위로, < 1이면 아래로 이동). analysis에 저장된 원본
  // 스펙트로그램은 건드리지 않고 이 함수 안에서만 워핑된 사본을 새로 만든다.
  std::vector<std::vector<double>> warpedStorage;
  std::vector<const double *> warpedSpectrogram;
  const double *const *synthesisSpectrogram = spectrogram.data();

  if (formantRatio > 0.0 && formantRatio != 1.0) {
    warpedStorage.assign(static_cast<size_t>(f0Length),
                          std::vector<double>(static_cast<size_t>(spectralSize)));
    warpedSpectrogram.resize(static_cast<size_t>(f0Length));
    for (int i = 0; i < f0Length; ++i) {
      const double *source = spectrogram[static_cast<size_t>(i)];
      double *dest = warpedStorage[static_cast<size_t>(i)].data();
      for (int k = 0; k < spectralSize; ++k) {
        double sourceIndex = static_cast<double>(k) / formantRatio;
        if (sourceIndex <= 0.0) {
          dest[k] = source[0];
        } else if (sourceIndex >= spectralSize - 1) {
          dest[k] = source[spectralSize - 1];
        } else {
          int lower = static_cast<int>(sourceIndex);
          double frac = sourceIndex - lower;
          dest[k] = source[lower] * (1.0 - frac) + source[lower + 1] * frac;
        }
      }
      warpedSpectrogram[static_cast<size_t>(i)] = dest;
    }
    synthesisSpectrogram = warpedSpectrogram.data();
  }

  // WORLD의 Synthesis 시그니처가 double *const * (비-const 포인터 배열)를 요구해서,
  // analysis에 저장된 데이터를 바꾸지 않는다는 전제 하에 const를 벗겨 전달한다 — Synthesis는
  // 스펙트로그램/비주기성을 읽기만 하고 쓰지 않는다(WORLD 소스 계약, 벤더 코드는 안 건드림).
  Synthesis(modifiedF0, f0Length, const_cast<double *const *>(synthesisSpectrogram),
            const_cast<double *const *>(aperiodicity.data()), analysis->fftSize,
            analysis->framePeriod, analysis->sampleRate, analysis->length, output);
}

void HumonyWorldFreeAnalysis(HumonyWorldAnalysis *analysis) {
  delete analysis;
}

void HumonyWorldPitchShift(const double *input, int length, int sampleRate,
                               double pitchRatio, double formantRatio, double *output) {
  if (length <= 0) {
    return;
  }
  if (pitchRatio <= 0.0) {
    std::memcpy(output, input, sizeof(double) * static_cast<size_t>(length));
    return;
  }

  // 129절 — 이 함수는 이제 handle 기반 API의 얇은 래퍼다: 한 번 분석하고, F0 전체를
  // pitchRatio배로 스케일한 곡선으로 한 번 재합성한다. 기존 호출부(단일 세그먼트를 한 번에
  // 옮기는 경우)와 동작이 정확히 같아야 하므로 별도 로직 없이 아래 두 함수만 그대로 호출한다.
  // world::kThreshold(0.85)는 InitializeD4COption의 기본값과 정확히 같은 값이라, 이 호출은
  // 132절 이전(d4cThreshold 파라미터가 없던 시절)과 바이트 단위로 동일한 동작을 낸다.
  HumonyWorldAnalysis *analysis = HumonyWorldAnalyze(input, length, sampleRate, world::kThreshold);
  if (!analysis) {
    std::memcpy(output, input, sizeof(double) * static_cast<size_t>(length));
    return;
  }

  std::vector<double> shiftedF0(static_cast<size_t>(analysis->f0Length));
  for (int i = 0; i < analysis->f0Length; ++i) {
    double original = analysis->f0[static_cast<size_t>(i)];
    shiftedF0[static_cast<size_t>(i)] = original > 0.0 ? original * pitchRatio : 0.0;
  }

  HumonyWorldSynthesizeWithF0(analysis, shiftedF0.data(), formantRatio, output);
  HumonyWorldFreeAnalysis(analysis);
}
