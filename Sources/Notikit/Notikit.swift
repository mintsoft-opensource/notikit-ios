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

    @discardableResult
    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let headers = ["content-type": "application/json", "api-key": apiKey]

        let compact = body.filter { !($0.value is NSNull) }
        let data = try JSONSerialization.data(withJSONObject: compact)
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
