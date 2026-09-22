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

final class NotikitTests: XCTestCase {
    func testRegisterDeviceSendsApiKeyAndPayload() async throws {
        let fake = FakeTransport(status: 201, json: #"{"success":true,"data":{"device":{"id":"d1","token":"t1","platform":"ios","isActive":true}},"error":null}"#)
        let notikit = Notikit(baseUrl: "https://push.test/", apiKey: "nk_test", transport: fake)

        let device = try await notikit.registerDevice(token: "t1", platform: "ios", externalId: "u1", identityHash: "h")
        XCTAssertEqual(device.id, "d1")
        XCTAssertEqual(device.platform, "ios")

        XCTAssertEqual(fake.lastURL?.absoluteString, "https://push.test/api/v1/devices")
        XCTAssertEqual(fake.lastHeaders?["api-key"], "nk_test")
        let body = try JSONSerialization.jsonObject(with: fake.lastBody!) as! [String: Any]
        XCTAssertEqual(body["external_id"] as? String, "u1")
        XCTAssertEqual(body["identity_hash"] as? String, "h")
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
            try await notikit.identify(externalId: "u1")
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
}
