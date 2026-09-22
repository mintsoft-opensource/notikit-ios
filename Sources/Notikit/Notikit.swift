import Foundation

public struct NotikitHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// 테스트/커스텀을 위한 HTTP 추상화.
///
/// `Sendable` 은 지금 붙여야 한다. Swift 6 로 넘어간 뒤에 붙이면 기존 구현체가 전부 깨진다.
public protocol NotikitHTTPTransport: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws -> NotikitHTTPResponse
}

/// 등록된 디바이스.
///
/// 공개 API 가 `[String: Any]` 를 돌려주면 Swift 6 에서 막힌다 — `Any` 는 Sendable 이 될 수
/// 없어 async 반환값으로 격리 경계를 넘지 못한다. 나중에 바꾸면 시그니처 파괴이므로
/// 처음부터 구체 타입으로 둔다.
public struct NotikitDevice: Sendable {
    public let id: String
    public let token: String
    public let platform: String
    public let userId: String?
    public let isActive: Bool

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let token = json["token"] as? String,
              let platform = json["platform"] as? String else { return nil }
        self.id = id
        self.token = token
        self.platform = platform
        self.userId = json["userId"] as? String
        self.isActive = (json["isActive"] as? Bool) ?? true
    }
}

public struct NotikitError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let status: Int
    public var description: String { "NotikitError(\(status)): \(message)" }
}

/// Notikit Swift SDK — 유저 중심 푸시 등록/식별.
/// APNs/FCM 토큰은 앱이 획득하고, 이 SDK 가 서버에 등록한다. (api-key 공개키만)
public final class Notikit: Sendable {
    private let baseUrl: String
    private let apiKey: String
    private let transport: any NotikitHTTPTransport

    public init(baseUrl: String, apiKey: String, transport: (any NotikitHTTPTransport)? = nil) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.apiKey = apiKey
        self.transport = transport ?? URLSessionTransport()
    }

    /// 미지정(NSNull) 필드를 제거하고 전송 — 서버가 기존 값을 유지하게 한다.
    @discardableResult
    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        return try await postRaw(path, body.filter { !($0.value is NSNull) })
    }

    /// NSNull 을 그대로 실어 전송 — 명시적 해제(external_id: null)와 미지정을 구분해야 할 때.
    @discardableResult
    private func postRaw(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let headers = ["content-type": "application/json", "api-key": apiKey]

        let data = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: baseUrl + path) else {
            throw NotikitError(message: "Invalid URL", status: 0)
        }
        let res = try await transport.post(url: url, headers: headers, body: data)
        guard let json = try? JSONSerialization.jsonObject(with: res.body) as? [String: Any] else {
            throw NotikitError(message: "Invalid response", status: res.status)
        }
        let success = (json["success"] as? Bool) ?? false
        if res.status >= 400 || !success {
            throw NotikitError(message: (json["error"] as? String) ?? "Request failed", status: res.status)
        }
        return (json["data"] as? [String: Any]) ?? [:]
    }

    @discardableResult
    public func registerDevice(
        token: String,
        platform: String,
        externalId: String? = nil,
        identityHash: String? = nil,
        locale: String? = nil,
        timezone: String? = nil
    ) async throws -> NotikitDevice {
        var body: [String: Any] = ["token": token, "platform": platform]
        if let ext = externalId {
            body["external_id"] = ext
            if let h = identityHash { body["identity_hash"] = h }
        }
        if let l = locale { body["locale"] = l }
        if let tz = timezone { body["timezone"] = tz }
        let data = try await post("/api/v1/devices", body)
        guard let d = data["device"] as? [String: Any], let device = NotikitDevice(json: d) else {
            throw NotikitError(message: "Malformed device response", status: 0)
        }
        return device
    }

    public func identify(externalId: String, identityHash: String? = nil, attributes: [String: String]? = nil) async throws {
        var body: [String: Any] = ["external_id": externalId]
        if let h = identityHash { body["identity_hash"] = h }
        if let a = attributes { body["attributes"] = a }
        try await post("/api/v1/users/identify", body)
    }

    /// 앱 열림 보고 — 접속 통계(DAU/WAU/MAU)의 원천.
    /// registerDevice 는 무거우므로 앱을 열 때마다는 이쪽을 쓴다.
    @discardableResult
    public func ping(token: String) async throws -> Bool {
        let data = try await post("/api/v1/devices/ping", ["token": token])
        return (data["recorded"] as? Bool) ?? false
    }

    /// 토픽 구독. 규칙으로 채워지는 토픽은 명단이 자동으로 정해지므로 409 가 온다.
    public func subscribe(topic: String, token: String) async throws {
        try await post("/api/v1/topics/subscribe", ["topic": topic, "token": token])
    }

    /// 토픽 구독 해지.
    ///
    /// 알림 설정 토글을 끄는 경로다. 이게 없으면 유저가 한 번 켠 토픽을 앱에서 끌 수 없다.
    /// 구독과 달리 없는 토픽을 만들지 않는다 — 없으면 404.
    public func unsubscribe(topic: String, token: String) async throws {
        try await post("/api/v1/topics/unsubscribe", ["topic": topic, "token": token])
    }

    /// 디바이스 바인딩 해제 (로그아웃/계정전환).
    /// 해제하지 않으면 이후 클릭이 이전 계정에 계속 귀속된다.
    public func unbindDevice(token: String, platform: String, identityHash: String? = nil) async throws {
        var body: [String: Any] = ["token": token, "platform": platform, "external_id": NSNull()]
        // 서버가 현재 바인딩된 유저의 해시를 검증한다 — 남의 토큰으로 해제하는 것을 막는다
        if let h = identityHash { body["identity_hash"] = h }
        // post 는 NSNull 을 제거하므로 명시적 해제는 raw 경로로 보낸다 —
        // 제거되면 external_id 없는 일반 업서트가 되어 바인딩이 그대로 남는다
        try await postRaw("/api/v1/devices", body)
    }

    /// 푸시 클릭(알림 탭) 보고.
    /// 유저는 서버가 토큰의 바인딩에서 해석하므로 externalId 를 보내지 않는다.
    @discardableResult
    public func reportClick(logId: String, token: String, destination: String? = nil) async throws -> Bool {
        var body: [String: Any] = ["log_id": logId, "token": token]
        if let d = destination { body["destination"] = d }
        let data = try await post("/api/v1/messages/click", body)
        return (data["recorded"] as? Bool) ?? false
    }

    /// 푸시 토큰 교체.
    ///
    /// 새 토큰으로 registerDevice 를 부르면 **행이 하나 더 생겨** 같은 사람에게 중복
    /// 발송된다. 서버가 기존 행을 제자리 갱신하게 해 토픽 구독·클릭 이력을 보존한다.
    @discardableResult
    public func rotateToken(oldToken: String, newToken: String, identityHash: String? = nil) async throws -> Bool {
        var body: [String: Any] = ["old_token": oldToken, "new_token": newToken]
        if let h = identityHash { body["identity_hash"] = h }
        let data = try await post("/api/v1/devices/rotate", body)
        return (data["rotated"] as? Bool) ?? false
    }

    /// 알림 탭 처리 — APNs userInfo 를 그대로 넘기면 된다.
    ///
    /// 탭 이벤트는 `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`
    /// 로 들어오는데, 델리게이트는 앱이 하나만 가질 수 있어 SDK 가 가져가면 앱 것을 빼앗는다.
    /// 그래서 델리게이트는 앱이 유지하고 이 메서드만 호출한다:
    ///
    ///     func userNotificationCenter(_ c: UNUserNotificationCenter,
    ///                                 didReceive response: UNNotificationResponse) async {
    ///         try? await notikit.handleNotificationOpen(response.notification.request.content.userInfo, token: token)
    ///     }
    ///
    /// notikit 이 보낸 알림이 아니면 아무 것도 하지 않는다 — 다른 경로의 알림까지
    /// 클릭으로 세면 클릭률이 부풀려진다.
    @discardableResult
    public func handleNotificationOpen(_ userInfo: [AnyHashable: Any], token: String, destination: String? = nil) async throws -> Bool {
        guard let logId = Notikit.logId(fromPayload: userInfo) else { return false }
        _ = try await reportClick(logId: logId, token: token, destination: destination)
        return true
    }

    /// 푸시 페이로드에서 notikit 이 예약해 쓰는 data 키
    public static let logIdKey = "notikit_log_id"

    /// APNs userInfo 에서 발송 id 추출 — 없으면 notikit 발송이 아니다
    public static func logId(fromPayload userInfo: [AnyHashable: Any]) -> String? {
        guard let v = userInfo[logIdKey] as? String, !v.isEmpty else { return nil }
        return v
    }

    /// 푸시 페이로드에서 딥링크 추출
    public static func deepLink(fromPayload userInfo: [AnyHashable: Any]) -> String? {
        guard let v = userInfo["deep_link"] as? String, !v.isEmpty else { return nil }
        return v
    }

    /// notikit·FCM·APNs 가 쓰는 키. 이것을 뺀 나머지가 발송 때 넣은 커스텀 필드다(서버의 금지 키 목록과 같다).
    private static let internalKeys: Set<String> = [
        "deep_link", logIdKey, "title", "body", "icon",
        "aps", "from", "collapse_key", "notification", "message_type", "fcm_options",
    ]
    private static let internalPrefixes = ["google.", "gcm."]

    /// 발송 때 넣은 커스텀 필드(템플릿 필드 포함)만 골라낸다. 알림 탭의 `userInfo` 를 그대로 넘기면 된다.
    public static func customData(fromPayload userInfo: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in userInfo {
            guard let key = k as? String, let value = v as? String else { continue }
            if internalKeys.contains(key) || internalPrefixes.contains(where: { key.hasPrefix($0) }) { continue }
            out[key] = value
        }
        return out
    }
}

final class URLSessionTransport: NotikitHTTPTransport, Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws -> NotikitHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return NotikitHTTPResponse(status: status, body: data)
    }
}
