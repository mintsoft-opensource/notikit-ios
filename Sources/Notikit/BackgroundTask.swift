import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/**
 알림 탭 직후의 짧은 실행 유예.

 탭하고 곧바로 홈으로 나가면 앱이 서스펜드되고 진행 중이던 요청이 잘린다. 클릭 보고는
 정확히 그 순간에 일어나므로, 유예를 잡지 않으면 iOS 클릭이 조용히 새어 나간다.

 UIKit 이 없는 플랫폼(macOS 등)에서는 아무 것도 하지 않는다 — 서스펜션 개념이 없다.
 */
final class NotikitBackgroundTask: @unchecked Sendable {
    #if canImport(UIKit) && !os(watchOS)
    private var id: UIBackgroundTaskIdentifier = .invalid
    private let lock = NSLock()

    init() {
        // 만료 핸들러에서 반드시 끝내야 한다 — 안 끝내면 시스템이 앱을 종료한다.
        let task = UIApplication.shared.beginBackgroundTask(withName: "notikit.click") { [weak self] in
            self?.end()
        }
        lock.lock()
        id = task
        lock.unlock()
    }

    func end() {
        lock.lock()
        let task = id
        id = .invalid
        lock.unlock()
        guard task != .invalid else { return } // 중복 호출 방지(만료 핸들러 + 정상 종료)
        UIApplication.shared.endBackgroundTask(task)
    }
    #else
    init() {}
    func end() {}
    #endif
}
