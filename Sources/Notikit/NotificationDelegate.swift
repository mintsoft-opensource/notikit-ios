#if canImport(UserNotifications)
import Foundation
import UserNotifications

/**
 알림 탭을 자동으로 잡는 델리게이트.

 `UNUserNotificationCenter.delegate` 는 앱당 하나뿐이라 SDK 가 그냥 차지하면 앱(또는
 Firebase)이 쓰던 델리게이트가 끊긴다. 그래서 **가로채지 않고 앞에 끼운다** — 우리가 먼저
 클릭을 기록하고, 원래 델리게이트로 그대로 넘긴다. Firebase 가 쓰는 방식과 같다.

 사용:

     Notikit.installNotificationDelegate(client: notikit, token: fcmToken)

 이미 델리게이트가 설정돼 있어야 체인이 이어지므로, **Firebase 설정 이후에** 호출한다.

 델리게이트 콜백은 메인 스레드로 오고 `UNUserNotificationCenter.delegate` 도 메인에서
 다룬다. `@MainActor` 는 **지금** 붙여야 한다 — Swift 6 로 넘어간 뒤에 붙이면
 installNotificationDelegate 호출부가 전부 깨진다. 프로토콜 요구사항 자체는
 nonisolated 라 `@preconcurrency` 로 받는다(사실상 메인 스레드 전용인 델리게이트의 표준 처리).
 */
@MainActor
public final class NotikitNotificationDelegate: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    /// 원래 델리게이트. 우리가 처리한 뒤 그대로 넘긴다.
    /// 재설치가 체인을 쌓지 않도록 install 에서 물려받아야 해 internal 로 둔다.
    let previous: (any UNUserNotificationCenterDelegate)?
    private let session: NotikitSession
    private let token: @Sendable () -> String?

    init(session: NotikitSession, previous: (any UNUserNotificationCenterDelegate)?, token: @escaping @Sendable () -> String?) {
        self.session = session
        self.previous = previous
        self.token = token
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // 보고는 백그라운드로 띄우고 **기다리지 않는다**. 완료 핸들러를 붙잡으면
        // 네트워크가 느릴 때 탭 반응이 눈에 띄게 늦어진다.
        //
        // 세션을 거치므로 실패해도 큐에 남아 다음 flush 에서 재시도한다. 예전에는
        // `try?` 로 에러를 버려 오프라인 탭이 그대로 사라졌다.
        if let logId = Notikit.logId(fromPayload: userInfo), let tok = token() {
            let destination = userInfo["deep_link"] as? String
            let session = self.session
            Task {
                // 탭 직후 홈으로 나가면 앱이 곧 서스펜드되어 전송이 중단된다.
                // 짧은 유예를 얻어 보고를 끝내거나, 최소한 큐에 적재되게 한다.
                let bg = NotikitBackgroundTask()
                await session.reportClick(logId: logId, token: tok, destination: destination)
                bg.end()
            }
        }

        // 원래 델리게이트가 이 메서드를 구현했으면 완료 핸들러도 그쪽이 부른다.
        // 구현하지 않았다면 우리가 불러야 한다 — 안 부르면 시스템이 경고를 남긴다.
        if let previous, previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }

    /// 포그라운드 표시 정책은 우리가 정할 일이 아니다 — 원래 델리게이트에 그대로 위임한다.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        if let previous, previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
        } else {
            completionHandler([])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        if let previous, previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:openSettingsFor:))) {
            previous.userNotificationCenter?(center, openSettingsFor: notification)
        }
    }
}

extension Notikit {
    /// 설치된 델리게이트를 붙잡아 둔다. `UNUserNotificationCenter.delegate` 는 weak 라
    /// 여기서 강하게 참조하지 않으면 곧바로 해제된다.
    @MainActor private static var installed: NotikitNotificationDelegate?

    /**
     알림 탭 자동 보고를 설치한다. 기존 델리게이트는 체인으로 이어진다.

     - Parameter token: 현재 푸시 토큰을 돌려주는 클로저. 토큰은 갱신될 수 있어
       값이 아니라 클로저로 받는다 — 값으로 받으면 갱신 후 클릭이 매칭되지 않는다.
     - Returns: 설치된 델리게이트와 클릭 큐를 쥔 세션. 로그인/로그아웃·토큰 교체에 그대로 쓴다.
     */
    @MainActor
    @discardableResult
    public static func installNotificationDelegate(
        client: Notikit,
        storage: any NotikitStorage = NotikitUserDefaultsStorage(),
        token: @escaping @Sendable () -> String?
    ) -> NotikitSession {
        let center = UNUserNotificationCenter.current()
        let session = NotikitSession(client: client, storage: storage)

        // 이미 우리 델리게이트가 붙어 있으면 그 **앞의 원본**을 물려받는다.
        // 그대로 체이닝하면 우리가 우리 자신 뒤에 서서, 재설치할 때마다 체인이
        // 무한히 길어지고 탭 한 번이 설치 횟수만큼 보고된다(토큰 갱신 때 흔히 재설치한다).
        let existing = center.delegate as? NotikitNotificationDelegate
        let base = existing?.previous ?? center.delegate

        let chained = NotikitNotificationDelegate(session: session, previous: base, token: token)
        center.delegate = chained
        installed = chained

        // 밀린 클릭·언바인딩 재전송 — 앱이 다시 열린 지금이 재시도할 때다
        Task { await session.flush() }
        return session
    }

    /// 고정 토큰용 간편 오버로드.
    @MainActor
    @discardableResult
    public static func installNotificationDelegate(client: Notikit, token: String) -> NotikitSession {
        installNotificationDelegate(client: client, token: { token })
    }
}
#endif
