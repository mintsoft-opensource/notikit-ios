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
}
