import XCTest
@testable import Notikit

final class FakeTransport: NotikitHTTPTransport, @unchecked Sendable {
    let status: Int
    let body: Data
    var lastURL: URL?
    var lastHeaders: [String: String]?
    var lastBody: Data?

    init(status: Int, json: String) {
        self.status = status
        self.body = json.data(using: .utf8)!
    }

    func post(url: URL, headers: [String: String], body: Data) async throws -> NotikitHTTPResponse {
        lastURL = url
        lastHeaders = headers
        lastBody = body
        return NotikitHTTPResponse(status: status, body: self.body)
    }
}

final class MemoryStorage: NotikitStorage, @unchecked Sendable {
    private var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func set(_ key: String, _ value: String) { values[key] = value }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}

private func sentBody(_ fake: FakeTransport) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: fake.lastBody ?? Data()) as? [String: Any] ?? [:]
}


/// 경로별로 응답을 정해 두는 가짜 전송. 경로에 남은 응답이 없으면 마지막 응답을 반복한다.
/// status 가 nil 이면 네트워크 오류를 던진다.
final class ScriptedTransport: NotikitHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: [(Int?, String)]] = [:]
    private(set) var calls: [(path: String, body: [String: Any])] = []

    func on(_ path: String, _ status: Int?, _ json: String = #"{"success":true,"data":{},"error":null}"#) {
        lock.lock(); defer { lock.unlock() }
        scripts[path, default: []].append((status, json))
    }

    func calls(to path: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.path == path }.map { $0.body }
    }

    func post(url: URL, headers: [String: String], body: Data) async throws -> NotikitHTTPResponse {
        let path = url.path
        let parsed = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let next: (Int?, String)? = {
            lock.lock(); defer { lock.unlock() }
            calls.append((path, parsed))
            guard var list = scripts[path], let first = list.first else { return nil }
            if list.count > 1 { list.removeFirst(); scripts[path] = list }
            return first
        }()
        guard let (status, json) = next else { return NotikitHTTPResponse(status: 404, body: Data(#"{"success":false,"data":null,"error":"no script"}"#.utf8)) }
        guard let st = status else { throw URLError(.notConnectedToInternet) }
        return NotikitHTTPResponse(status: st, body: Data(json.utf8))
    }
}

private let deviceJSON = #"{"success":true,"data":{"device":{"id":"d2","token":"new","platform":"ios","isActive":true}},"error":null}"#
private let failJSON = #"{"success":false,"data":null,"error":"x"}"#

private func queueTokens(_ storage: MemoryStorage) -> [String] {
    guard let raw = storage.get("clickQueue"),
          let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return [] }
    return arr.compactMap { $0["token"] as? String }
}

private func pendingUnbind(_ storage: MemoryStorage) -> [String: Any]? {
    guard let raw = storage.get("pendingUnbind") else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
}

final class NotikitTests: XCTestCase {
    func testRegisterDeviceSendsApiKeyAndPayload() async throws {
        let fake = FakeTransport(status: 201, json: #"{"success":true,"data":{"device":{"id":"d1","token":"t1","platform":"ios","isActive":true}},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test/", apiKey: "nk_test", transport: fake)

        let device = try await notikit.registerDevice(token: "t1", platform: "ios", userId: "u1", identityHash: "h")
        XCTAssertEqual(device.id, "d1")
        XCTAssertEqual(device.platform, "ios")

        XCTAssertEqual(fake.lastURL?.absoluteString, "https://push.test/api/v1/devices")
        XCTAssertEqual(fake.lastHeaders?["api-key"], "nk_test")
        let body = try JSONSerialization.jsonObject(with: fake.lastBody!) as! [String: Any]
        XCTAssertEqual(body["user_id"] as? String, "u1")
        XCTAssertNil(body["external_id"])
        XCTAssertEqual(body["identity_hash"] as? String, "h")
    }

    func testIdentifySendsName() async throws {
        let fake = FakeTransport(status: 200, json: #"{"success":true,"data":{},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)
        try await notikit.identify(userId: "u1", name: "김민지")
        let body = try JSONSerialization.jsonObject(with: fake.lastBody ?? Data()) as? [String: Any] ?? [:]
        XCTAssertEqual(body["name"] as? String, "김민지")
    }

    func testOmitsApiSecretWhenNotProvided() async throws {
        let fake = FakeTransport(status: 200, json: #"{"success":true,"data":{},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)
        try await notikit.subscribe(topic: "news", token: "t1")
        XCTAssertNil(fake.lastHeaders?["api-secret"])
    }

    func testThrowsOnFailure() async {
        let fake = FakeTransport(status: 401, json: #"{"success":false,"data":null,"error":"Unauthorized"}"#)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)
        do {
            try await notikit.identify(userId: "u1")
            XCTFail("should throw")
        } catch let e as NotikitError {
            XCTAssertEqual(e.status, 401)
        } catch {
            XCTFail("wrong error type")
        }
    }

    func testCustomDataSkipsNotikitFcmAndApnsKeys() {
        let userInfo: [AnyHashable: Any] = [
            "notikit_log_id": "log1",
            "deep_link": "myapp://orders",
            "aps": ["alert": ["title": "t"]],
            "google.c.a.e": "1",
            "gcm.message_id": "x",
            "order_id": "A-1",
            "screen": "order",
        ]
        XCTAssertEqual(Notikit.customData(fromPayload: userInfo), ["order_id": "A-1", "screen": "order"])
        XCTAssertEqual(Notikit.deepLink(fromPayload: userInfo), "myapp://orders")
        XCTAssertEqual(Notikit.customData(fromPayload: [:]), [:])
    }

    func testIdentifyByUserIdSendsOnlyUserId() async throws {
        let fake = FakeTransport(status: 200, json: #"{"success":true,"data":{},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)
        try await notikit.identify(userId: "u1", identityHash: "h")
        let body = try sentBody(fake)
        XCTAssertEqual(body["user_id"] as? String, "u1")
        XCTAssertNil(body["external_id"])
        XCTAssertEqual(body["identity_hash"] as? String, "h")
    }

    @available(*, deprecated)
    func testDeprecatedExternalIdStillSendsUserId() async throws {
        let fake = FakeTransport(status: 201, json: #"{"success":true,"data":{"device":{"id":"d1","token":"t1","platform":"ios","isActive":true}},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)

        _ = try await notikit.registerDevice(token: "t1", platform: "ios", externalId: "u1", identityHash: "h")
        var body = try sentBody(fake)
        XCTAssertEqual(body["user_id"] as? String, "u1")
        XCTAssertNil(body["external_id"])

        try await notikit.identify(externalId: "u2")
        body = try sentBody(fake)
        XCTAssertEqual(body["user_id"] as? String, "u2")
        XCTAssertNil(body["external_id"])

        let user = NotikitStoredUser(externalId: "u3")
        XCTAssertEqual(user.userId, "u3")
        XCTAssertEqual(user.externalId, "u3")
    }

    func testUnbindSendsExplicitNullUserId() async throws {
        let fake = FakeTransport(status: 200, json: #"{"success":true,"data":{"device":{}},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)
        try await notikit.unbindDevice(token: "t1", platform: "ios", identityHash: "h")
        let body = try sentBody(fake)
        XCTAssertTrue(body["user_id"] is NSNull)
        XCTAssertNil(body["external_id"])
        XCTAssertEqual(body["token"] as? String, "t1")
    }

    func testSessionLoginStoresUserIdAndBindsWithUserId() async throws {
        let fake = FakeTransport(status: 201, json: #"{"success":true,"data":{"device":{"id":"d1","token":"t1","platform":"ios","isActive":true}},"error":null}"#)
        let storage = MemoryStorage()
        let session = NotikitSession(client: Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake), storage: storage)

        try await session.login(user: NotikitStoredUser(userId: "u1", identityHash: "h"), token: "t1")

        let body = try sentBody(fake)
        XCTAssertEqual(body["user_id"] as? String, "u1")
        XCTAssertNil(body["external_id"])
        let stored = try JSONSerialization.jsonObject(with: Data(storage.get("user")!.utf8)) as? [String: Any]
        XCTAssertEqual(stored?["userId"] as? String, "u1")
        let user = await session.getUser()
        XCTAssertEqual(user, NotikitStoredUser(userId: "u1", identityHash: "h"))
    }

    func testSessionReadsUserStoredWithLegacyKey() async throws {
        let fake = FakeTransport(status: 200, json: #"{"success":true,"data":{},"error":null}"#)
        let storage = MemoryStorage()
        storage.set("user", #"{"externalId":"legacy","identityHash":"h"}"#)
        let session = NotikitSession(client: Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake), storage: storage)

        let user = await session.getUser()
        XCTAssertEqual(user, NotikitStoredUser(userId: "legacy", identityHash: "h"))
    }

    func testFlushSendsLegacyQueuedClickOfCurrentUser() async throws {
        let fake = FakeTransport(status: 200, json: #"{"success":true,"data":{"recorded":true},"error":null}"#)
        let storage = MemoryStorage()
        storage.set("user", #"{"externalId":"u1"}"#)
        let at = Date().timeIntervalSince1970
        storage.set("clickQueue", #"[{"logId":"l1","token":"t1","at":\#(at),"externalId":"u1"},{"logId":"l2","token":"t1","at":\#(at),"externalId":"other"}]"#)
        let session = NotikitSession(client: Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake), storage: storage)

        let sent = await session.flush()
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(try sentBody(fake)["log_id"] as? String, "l1")
    }

    // MARK: - 토큰 교체

    private func seededSession(_ fake: ScriptedTransport, pending: Bool = false) -> (NotikitSession, MemoryStorage) {
        let storage = MemoryStorage()
        storage.set("user", #"{"userId":"u1","identityHash":"h1"}"#)
        let at = Date().timeIntervalSince1970
        storage.set("clickQueue", #"[{"logId":"l1","token":"old","at":\#(at),"userId":"u1"}]"#)
        if pending { storage.set("pendingUnbind", #"{"token":"old","identityHash":"h0","at":\#(at)}"#) }
        let session = NotikitSession(client: Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake), storage: storage)
        return (session, storage)
    }

    func testRotateNotRotatedFallsBackToRegisterAndMovesQueue() async throws {
        let fake = ScriptedTransport()
        fake.on("/api/v1/devices/rotate", 202, #"{"success":true,"data":{"rotated":false},"error":null}"#)
        fake.on("/api/v1/devices", 201, deviceJSON)
        let (session, storage) = seededSession(fake, pending: true)

        try await session.rotateToken(oldToken: "old", newToken: "new")

        let reg = fake.calls(to: "/api/v1/devices")
        XCTAssertEqual(reg.count, 1)
        XCTAssertEqual(reg.first?["token"] as? String, "new")
        XCTAssertEqual(reg.first?["user_id"] as? String, "u1")
        XCTAssertEqual(reg.first?["identity_hash"] as? String, "h1")
        XCTAssertEqual(queueTokens(storage), ["new"])
        // 재등록 경로에서는 옛 행이 이전 바인딩을 들고 있으므로 해제 대상은 옛 토큰 그대로
        XCTAssertEqual(pendingUnbind(storage)?["token"] as? String, "old")
    }

    func testRotateFallbackFailureThrowsAndKeepsQueue() async throws {
        let fake = ScriptedTransport()
        fake.on("/api/v1/devices/rotate", 202, #"{"success":true,"data":{"rotated":false},"error":null}"#)
        fake.on("/api/v1/devices", 403, failJSON)
        let (session, storage) = seededSession(fake)

        do {
            try await session.rotateToken(oldToken: "old", newToken: "new")
            XCTFail("should throw")
        } catch let e as NotikitError {
            XCTAssertEqual(e.status, 403)
        }
        XCTAssertEqual(queueTokens(storage), ["old"])
    }

    func testRotateRotatedMovesQueueAndPendingUnbind() async throws {
        let fake = ScriptedTransport()
        fake.on("/api/v1/devices/rotate", 202, #"{"success":true,"data":{"rotated":true,"device_id":"d1"},"error":null}"#)
        let (session, storage) = seededSession(fake, pending: true)

        try await session.rotateToken(oldToken: "old", newToken: "new")

        XCTAssertEqual(fake.calls(to: "/api/v1/devices").count, 0)
        XCTAssertEqual(fake.calls(to: "/api/v1/devices/rotate").first?["identity_hash"] as? String, "h1")
        XCTAssertEqual(queueTokens(storage), ["new"])
        XCTAssertEqual(pendingUnbind(storage)?["token"] as? String, "new")
        XCTAssertEqual(pendingUnbind(storage)?["identityHash"] as? String, "h0")
    }

    func testRotateSameTokenSendsNothing() async throws {
        let fake = ScriptedTransport()
        let (session, storage) = seededSession(fake)
        try await session.rotateToken(oldToken: "old", newToken: "old")
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(queueTokens(storage), ["old"])
    }

    // MARK: - 밀린 언바인딩

    func testPendingUnbindDroppedOnNonRetryable4xx() async throws {
        let fake = ScriptedTransport()
        fake.on("/api/v1/devices", 403, failJSON)
        let (session, storage) = seededSession(fake, pending: true)
        storage.remove("clickQueue")

        _ = await session.flush()
        XCTAssertNil(storage.get("pendingUnbind"))
    }

    func testPendingUnbindKeptOn5xxAnd429() async throws {
        let fake = ScriptedTransport()
        fake.on("/api/v1/devices", 500, failJSON)
        fake.on("/api/v1/devices", 429, failJSON)
        let (session, storage) = seededSession(fake, pending: true)
        storage.remove("clickQueue")

        _ = await session.flush()
        XCTAssertNotNil(storage.get("pendingUnbind"))
        _ = await session.flush()
        XCTAssertNotNil(storage.get("pendingUnbind"))
    }

    // MARK: - 수신 보고

    func testReportReceivedSendsOnceAndDedupes() async throws {
        let fake = ScriptedTransport()
        fake.on("/api/v1/messages/received", 202, #"{"success":true,"data":{"recorded":true},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)

        let first = try await notikit.reportReceived(logId: "l1", token: "t1")
        XCTAssertEqual(first, true)
        let second = try await notikit.reportReceived(logId: "l1", token: "t1")
        XCTAssertNil(second)
        let empty = try await notikit.reportReceived(logId: "", token: "t1")
        XCTAssertNil(empty)

        let calls = fake.calls(to: "/api/v1/messages/received")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["log_id"] as? String, "l1")
        XCTAssertEqual(calls.first?["token"] as? String, "t1")
    }

    func testReportReceivedReleasesOnRetryableFailure() async throws {
        let fake = ScriptedTransport()
        fake.on("/api/v1/messages/received", 500, failJSON)
        fake.on("/api/v1/messages/received", nil)
        fake.on("/api/v1/messages/received", 202, #"{"success":true,"data":{"recorded":true},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)

        do { _ = try await notikit.reportReceived(logId: "l1", token: "t1"); XCTFail("should throw") } catch {}
        do { _ = try await notikit.reportReceived(logId: "l1", token: "t1"); XCTFail("should throw") } catch {}
        let ok = try await notikit.reportReceived(logId: "l1", token: "t1")
        XCTAssertEqual(ok, true)
        XCTAssertEqual(fake.calls(to: "/api/v1/messages/received").count, 3)
    }

    func testReportReceivedKeepsOnClient4xx() async throws {
        let fake = ScriptedTransport()
        fake.on("/api/v1/messages/received", 404, failJSON)
        let notikit = Notikit(baseUrl: "https://push.test", apiKey: "nk", transport: fake)

        do { _ = try await notikit.reportReceived(logId: "l1", token: "t1"); XCTFail("should throw") } catch let e as NotikitError {
            XCTAssertEqual(e.status, 404)
        }
        let again = try await notikit.reportReceived(logId: "l1", token: "t1")
        XCTAssertNil(again)
        XCTAssertEqual(fake.calls(to: "/api/v1/messages/received").count, 1)
    }

    func testCustomDataSkipsActions() {
        let userInfo: [AnyHashable: Any] = [
            "notikit_log_id": "log1",
            "actions": #"[{"id":"a","title":"A"}]"#,
            "order_id": "A-1",
        ]
        XCTAssertEqual(Notikit.customData(fromPayload: userInfo), ["order_id": "A-1"])
    }
}
