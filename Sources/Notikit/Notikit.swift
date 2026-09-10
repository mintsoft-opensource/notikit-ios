import Foundation

public struct NotikitHTTPResponse {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// 테스트/커스텀을 위한 HTTP 추상화
public protocol NotikitHTTPTransport {
    func post(url: URL, headers: [String: String], body: Data) async throws -> NotikitHTTPResponse
}

public struct NotikitError: Error, CustomStringConvertible {
    public let message: String
    public let status: Int
    public var description: String { "NotikitError(\(status)): \(message)" }
}

/// Notikit Swift SDK — 유저 중심 푸시 등록/식별.
/// APNs/FCM 토큰은 앱이 획득하고, 이 SDK 가 서버에 등록한다. (api-key 공개키만)
public final class Notikit {
    private let baseUrl: String
    private let apiKey: String
    private let transport: NotikitHTTPTransport

    public init(baseUrl: String, apiKey: String, transport: NotikitHTTPTransport? = nil) {
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
    ) async throws -> [String: Any] {
        var body: [String: Any] = ["token": token, "platform": platform]
        if let ext = externalId {
            body["external_id"] = ext
            if let h = identityHash { body["identity_hash"] = h }
        }
        if let l = locale { body["locale"] = l }
        if let tz = timezone { body["timezone"] = tz }
        return try await post("/api/v1/devices", body)
    }

    @discardableResult
    public func identify(externalId: String, identityHash: String? = nil, attributes: [String: Any]? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["external_id": externalId]
        if let h = identityHash { body["identity_hash"] = h }
        if let a = attributes { body["attributes"] = a }
        return try await post("/api/v1/users/identify", body)
    }

    @discardableResult
    public func subscribe(topic: String, token: String) async throws -> [String: Any] {
        return try await post("/api/v1/topics/subscribe", ["topic": topic, "token": token])
    }

    /// 디바이스 바인딩 해제 (로그아웃/계정전환).
    /// 해제하지 않으면 이후 클릭이 이전 계정에 계속 귀속된다.
    @discardableResult
    public func unbindDevice(token: String, platform: String, identityHash: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["token": token, "platform": platform, "external_id": NSNull()]
        // 서버가 현재 바인딩된 유저의 해시를 검증한다 — 남의 토큰으로 해제하는 것을 막는다
        if let h = identityHash { body["identity_hash"] = h }
        // post 는 NSNull 을 제거하므로 명시적 해제는 raw 경로로 보낸다 —
        // 제거되면 external_id 없는 일반 업서트가 되어 바인딩이 그대로 남는다
        return try await postRaw("/api/v1/devices", body)
    }

    /// 푸시 클릭(알림 탭) 보고.
    /// 유저는 서버가 토큰의 바인딩에서 해석하므로 externalId 를 보내지 않는다.
    @discardableResult
    public func reportClick(logId: String, token: String, destination: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["log_id": logId, "token": token]
        if let d = destination { body["destination"] = d }
        return try await post("/api/v1/messages/click", body)
    }

    /// 푸시 페이로드에서 notikit 이 예약해 쓰는 data 키
    public static let logIdKey = "notikit_log_id"

    /// APNs userInfo 에서 발송 id 추출 — 없으면 notikit 발송이 아니다
    public static func logId(fromPayload userInfo: [AnyHashable: Any]) -> String? {
        guard let v = userInfo[logIdKey] as? String, !v.isEmpty else { return nil }
        return v
    }
}

final class URLSessionTransport: NotikitHTTPTransport {
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
