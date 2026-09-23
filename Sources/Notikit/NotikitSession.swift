import Foundation

/// 로그인한 유저. `identityHash` 는 고객 서버가 계산한 HMAC 이다.
public struct NotikitStoredUser: Sendable, Equatable {
    public let userId: String
    public let identityHash: String?
    public init(userId: String, identityHash: String? = nil) {
        self.userId = userId
        self.identityHash = identityHash
    }

    @available(*, deprecated, renamed: "init(userId:identityHash:)")
    public init(externalId: String, identityHash: String? = nil) {
        self.init(userId: externalId, identityHash: identityHash)
    }

    @available(*, deprecated, renamed: "userId")
    public var externalId: String { userId }
}

/// 키-값 영속 저장소. 기본 구현은 `UserDefaults` 를 쓴다.
///
/// 클릭은 앱이 죽은 상태에서 콜드 스타트로 들어오므로 메모리 저장은 쓸 수 없다.
public protocol NotikitStorage: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

/// `UserDefaults` 는 문서상 스레드 안전하지만 `Sendable` 로 표시돼 있지 않다.
/// 그대로 두면 Swift 6 에서 오류가 되므로 여기서 명시적으로 책임진다.
public struct NotikitUserDefaultsStorage: NotikitStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "notikit.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func get(_ key: String) -> String? { defaults.string(forKey: prefix + key) }
    public func set(_ key: String, _ value: String) { defaults.set(value, forKey: prefix + key) }
    public func remove(_ key: String) { defaults.removeObject(forKey: prefix + key) }
}

/**
 유저 바인딩과 **밀린 클릭 큐**를 담당한다.

 델리게이트에서 곧바로 `reportClick` 을 부르면 실패가 그대로 사라진다. 알림 탭은 하필
 네트워크가 없을 때(콜드 스타트 직후, 지하철) 가장 많이 일어나므로, 재시도가 없으면
 iOS 클릭률이 Android 보다 구조적으로 낮게 집계된다. Android 의 `NotikitSession` 과
 같은 규칙을 쓴다 — 최대 50건, 7일 TTL, 4xx 는 즉시 폐기.

 actor 라 큐의 read-modify-write 가 자동으로 직렬화된다.
 */
public actor NotikitSession {
    private let client: Notikit
    private let storage: any NotikitStorage
    private let platform: String

    private static let userKey = "user"
    private static let queueKey = "clickQueue"
    private static let unbindKey = "pendingUnbind"
    private static let queueMax = 50
    private static let queueTTL: TimeInterval = 7 * 24 * 60 * 60

    public init(client: Notikit, storage: any NotikitStorage = NotikitUserDefaultsStorage(), platform: String = "ios") {
        self.client = client
        self.storage = storage
        self.platform = platform
    }

    // MARK: - 유저

    public func getUser() -> NotikitStoredUser? {
        guard let raw = storage.get(Self.userKey),
              let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = Self.ownerId(o) else { return nil }
        return NotikitStoredUser(userId: uid, identityHash: o["identityHash"] as? String)
    }

    /// 로그인 — 유저를 저장하고 디바이스를 그 유저에 바인딩한다.
    public func login(user: NotikitStoredUser, token: String) async throws {
        var o: [String: Any] = ["userId": user.userId]
        if let h = user.identityHash { o["identityHash"] = h }
        store(Self.userKey, o)
        _ = try await client.registerDevice(
            token: token, platform: platform, userId: user.userId, identityHash: user.identityHash
        )
        // 밀린 언바인딩은 **새 바인딩이 서버에 반영된 뒤에만** 버린다. 먼저 지우면
        // 오프라인 로그아웃 후 오프라인 로그인이 실패했을 때 해제 요청이 사라져
        // 서버는 기기를 계속 이전 유저로 본다.
        storage.remove(Self.unbindKey)
    }

    /// 로그아웃 — 저장된 유저를 지우고 서버 바인딩도 해제한다.
    public func logout(token: String) async throws {
        let user = getUser()
        storage.remove(Self.userKey)
        // 이전 세션의 밀린 클릭은 버린다 — 지금 보내면 다음 로그인 유저에게 붙는다
        storage.remove(Self.queueKey)
        do {
            try await client.unbindDevice(token: token, platform: platform, identityHash: user?.identityHash)
        } catch {
            // 로그아웃은 오프라인에서 가장 자주 일어난다. 포기하면 서버 바인딩이 이전
            // 유저로 남아 다음 사람의 클릭이 그 유저에게 붙는다 — 재시도용으로 남긴다.
            var pending: [String: Any] = ["token": token, "at": Date().timeIntervalSince1970]
            if let h = user?.identityHash { pending["identityHash"] = h }
            store(Self.unbindKey, pending)
            throw error
        }
    }

    /// 푸시 토큰 교체. 밀린 클릭의 토큰도 함께 갱신한다 — 안 바꾸면 서버가 기기를
    /// 못 찾아 404 를 주고 4xx 정책에 걸려 전부 버려진다.
    public func rotateToken(oldToken: String, newToken: String) async throws {
        _ = try await client.rotateToken(
            oldToken: oldToken, newToken: newToken, identityHash: getUser()?.identityHash
        )
        var queue = readQueue()
        guard !queue.isEmpty else { return }
        for i in queue.indices where (queue[i]["token"] as? String) == oldToken {
            queue[i]["token"] = newToken
        }
        writeQueue(queue)
    }

    // MARK: - 클릭

    /// 클릭 보고. 실패하면 큐에 넣어 다음 flush 때 재시도한다.
    @discardableResult
    public func reportClick(logId: String, token: String, destination: String? = nil) async -> Bool {
        do {
            _ = try await client.reportClick(logId: logId, token: token, destination: destination)
            return true
        } catch {
            enqueue(logId: logId, token: token, destination: destination)
            return false
        }
    }

    /// 알림 탭 처리 — APNs userInfo 에서 발송 id 를 꺼내 보고한다.
    /// notikit 이 보낸 알림이 아니면 아무 것도 하지 않는다.
    @discardableResult
    public func handleNotificationOpen(logId: String, token: String, destination: String? = nil) async -> Bool {
        await reportClick(logId: logId, token: token, destination: destination)
    }

    /// 밀린 클릭 재전송 — SDK 초기화 직후·앱 포그라운드 진입 시 호출.
    @discardableResult
    public func flush() async -> Int {
        await retryPendingUnbind()

        let queue = readQueue()
        guard !queue.isEmpty else { return 0 }

        let now = Date().timeIntervalSince1970
        let current = getUser()?.userId
        // 스냅샷으로 큐를 덮어쓰지 않는다. actor 는 await 에서 **재진입**하므로,
        // 아래 네트워크 대기 중에 들어온 클릭이 스냅샷에는 없다 — 덮어쓰면 그 클릭이
        // 보내지지도 않은 채 사라진다. 지울 것만 모았다가 마지막에 빼낸다.
        var done = Set<String>()
        var sent = 0

        for c in queue {
            guard let logId = c["logId"] as? String, let token = c["token"] as? String else { continue }
            let key = "\(logId)|\(token)"

            if now - ((c["at"] as? TimeInterval) ?? 0) >= Self.queueTTL {
                done.insert(key) // 오래된 클릭은 버린다
                continue
            }

            // 지금 보내면 다음 사람에게 귀속되므로 보내지 않되, **버리지도 않는다**.
            // 비로그인 탭이 큐에 남았다가 로그인하면 어긋나는데, 여기서 폐기하면
            // 그 클릭이 영영 사라진다. TTL 이 수명을 제한한다.
            if Self.ownerId(c) != current { continue }

            do {
                _ = try await client.reportClick(logId: logId, token: token, destination: c["destination"] as? String)
                done.insert(key)
                sent += 1
            } catch let e as NotikitError {
                // 4xx 는 재시도해도 같다(토큰 교체로 404 등) — 7일간 두드리지 않고 버린다
                if e.status >= 400, e.status < 500, e.status != 429 { done.insert(key) }
            } catch {
                // 네트워크 오류 — 큐에 남겨 다음에 재시도한다
            }
        }

        guard !done.isEmpty else { return sent }
        // 지금 시점의 큐를 다시 읽어 처리한 것만 빼낸다 — flush 중 들어온 건은 남는다
        let remaining = readQueue().filter { c in
            guard let l = c["logId"] as? String, let t = c["token"] as? String else { return true }
            return !done.contains("\(l)|\(t)")
        }
        writeQueue(remaining)
        return sent
    }

    // MARK: - 내부

    /// 이전 버전은 `externalId` 키로 저장했다 — 업데이트 직후에도 읽히도록 둘 다 본다
    private static func ownerId(_ o: [String: Any]) -> String? {
        (o["userId"] as? String) ?? (o["externalId"] as? String)
    }

    private func retryPendingUnbind() async {
        guard let raw = storage.get(Self.unbindKey),
              let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = o["token"] as? String else { return }
        do {
            try await client.unbindDevice(token: token, platform: platform, identityHash: o["identityHash"] as? String)
            storage.remove(Self.unbindKey)
        } catch {
            // 다음 flush 에서 다시 시도한다
        }
    }

    private func enqueue(logId: String, token: String, destination: String?) {
        var queue = readQueue()
        // 같은 발송의 중복 클릭은 서버에서도 유니크로 걸리므로 큐 단계에서 미리 접는다
        if queue.contains(where: { ($0["logId"] as? String) == logId && ($0["token"] as? String) == token }) { return }

        var entry: [String: Any] = ["logId": logId, "token": token, "at": Date().timeIntervalSince1970]
        if let d = destination { entry["destination"] = d }
        if let owner = getUser()?.userId { entry["userId"] = owner }
        queue.append(entry)

        if queue.count > Self.queueMax { queue.removeFirst(queue.count - Self.queueMax) }
        writeQueue(queue)
    }

    private func readQueue() -> [[String: Any]] {
        guard let raw = storage.get(Self.queueKey),
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private func writeQueue(_ queue: [[String: Any]]) {
        guard !queue.isEmpty else {
            storage.remove(Self.queueKey)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: queue),
              let s = String(data: data, encoding: .utf8) else { return }
        storage.set(Self.queueKey, s)
    }

    private func store(_ key: String, _ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else { return }
        storage.set(key, s)
    }
}
