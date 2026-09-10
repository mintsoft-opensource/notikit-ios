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
 */
public final class NotikitNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// 원래 델리게이트. 우리가 처리한 뒤 그대로 넘긴다.
    private let previous: UNUserNotificationCenterDelegate?
    private let client: Notikit
    private let token: () -> String?

    init(client: Notikit, previous: UNUserNotificationCenterDelegate?, token: @escaping () -> String?) {
        self.client = client
        self.previous = previous
        self.token = token
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // 보고는 백그라운드로 띄우고 **기다리지 않는다**. 완료 핸들러를 붙잡으면
        // 네트워크가 느릴 때 탭 반응이 눈에 띄게 늦어진다.
        if let logId = Notikit.logId(fromPayload: userInfo), let tok = token() {
            let destination = userInfo["deep_link"] as? String
            Task { try? await client.reportClick(logId: logId, token: tok, destination: destination) }
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
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
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
    private static var installed: NotikitNotificationDelegate?

    /**
     알림 탭 자동 보고를 설치한다. 기존 델리게이트는 체인으로 이어진다.

     - Parameter token: 현재 푸시 토큰을 돌려주는 클로저. 토큰은 갱신될 수 있어
       값이 아니라 클로저로 받는다 — 값으로 받으면 갱신 후 클릭이 매칭되지 않는다.
     */
    @discardableResult
    public static func installNotificationDelegate(
        client: Notikit,
        token: @escaping () -> String?
    ) -> NotikitNotificationDelegate {
        let center = UNUserNotificationCenter.current()
        let chained = NotikitNotificationDelegate(client: client, previous: center.delegate, token: token)
        center.delegate = chained
        installed = chained
        return chained
    }

    /// 고정 토큰용 간편 오버로드.
    @discardableResult
    public static func installNotificationDelegate(client: Notikit, token: String) -> NotikitNotificationDelegate {
        installNotificationDelegate(client: client, token: { token })
    }
}
#endif
