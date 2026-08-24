//
//  이 파일은 Swift가 C/C++ 코드를 직접 부를 수 있게 연결하는 브리징 헤더다.
//  WORLD 보코더는 C++ 구현체지만 공개 API는 전부 C 링키지(extern "C")라, 얇은
//  래퍼(HarmonyUpWorldBridge)만 여기 노출하면 Swift에서 평범한 C 함수처럼 호출할 수 있다.
//
#import "HarmonyUpWorldBridge.h"
