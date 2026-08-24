import SwiftUI
import SwiftData

@main
struct HarmonyUpApp: App {
    // 컨테이너를 직접 만드는 이유는 아래 makeContainer()의 폴백 때문이다 —
    // `.modelContainer(for:)`는 생성이 실패하면 앱을 그대로 크래시시킨다.
    private let modelContainer = HarmonyUpApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }

    /// **136절, 스키마 재설계와 저장소 폴백**: 기록을 세션 단위(`PracticeSession` +
    /// `PracticeAttempt`)로 갈아엎으면서 기존 저장소와 스키마가 안 맞게 됐다 — SwiftData의 자동
    /// 마이그레이션은 필드 추가 정도는 넘기지만 이번처럼 모델 구조가 바뀌면 실패한다.
    ///
    /// 채점은 116절부터 화면에서 안 보였으니 실기기에 남은 기록이 사실상 없고, 사용자와 "기존
    /// 기록은 버린다"로 확정했다. 그래서 실패하면 저장소 파일을 지우고 새로 만든다 — 이 폴백이
    /// 없으면 앱이 아예 시작하지 못한다(첫 실행에서 크래시).
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([PracticeSession.self, PracticeAttempt.self])

        do {
            return try ModelContainer(for: schema)
        } catch {
            #if DEBUG
            print("[HarmonyUpApp] 저장소를 열지 못했다(스키마 불일치로 추정) — 비우고 다시 만든다: \(error)")
            #endif
            removeStoreFiles()
        }

        do {
            return try ModelContainer(for: schema)
        } catch {
            // 여기까지 실패하면 디스크 문제 등 저장 자체가 불가능한 상황이다. 기록을 못 남기더라도
            // 연습 기능(녹음/화음/채점)은 저장소와 무관하게 동작하니, 앱을 죽이는 대신 메모리
            // 전용으로 띄운다 — 앱을 다시 켜면 기록이 사라지지만 아무것도 못 하는 것보다 낫다.
            #if DEBUG
            print("[HarmonyUpApp] 저장소를 새로 만들지도 못했다 — 메모리 전용으로 실행한다: \(error)")
            #endif
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // 메모리 전용 컨테이너까지 실패하는 경우는 스키마 자체가 잘못된 것(개발 중 실수)이라
            // 조용히 넘기면 오히려 발견이 늦어진다.
            return try! ModelContainer(for: schema, configurations: inMemory)
        }
    }

    /// SwiftData 기본 저장소 파일들 — SQLite 본체와 함께 WAL/공유메모리 파일도 지워야 한다
    /// (본체만 지우면 남은 -wal에 이전 스키마의 내용이 남아 다시 열 때 또 실패할 수 있다).
    private static func removeStoreFiles() {
        let base = URL.applicationSupportDirectory.appending(path: "default.store")
        for path in [base.path, base.path + "-wal", base.path + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
