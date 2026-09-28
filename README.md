# Notikit (Swift)

> Notikit Swift SDK — 유저 중심 푸시 디바이스 등록/식별 (async/await).

[소개](https://notikit.mint-soft.com) · [서버](https://github.com/mintsoft-opensource/notikit) · 다른 SDK: [JS](https://github.com/mintsoft-opensource/notikit-js) · [Android](https://github.com/mintsoft-opensource/notikit-android) · [Flutter](https://github.com/mintsoft-opensource/notikit-flutter)

## 설치 (SPM)
```swift
.package(url: "https://github.com/mintsoft-opensource/notikit-ios", from: "0.1.0")
```

CocoaPods 는 아직 지원하지 않는다(podspec 미제공).

## 사용
```swift
import Notikit

let notikit = Notikit(baseUrl: "https://push.example.com", apiKey: "nk_xxx") // 공개키만

// APNs/FCM 토큰 획득 후
try await notikit.registerDevice(
    token: fcmToken,
    platform: "ios",
    userId: "user-123", // 고객 서비스의 유저 id
    identityHash: "<서버계산 HMAC>"
)
```

## API
| | 설명 |
|---|---|
| `registerDevice(token:platform:userId:identityHash:...)` | 토큰 등록 |
| `identify(userId:identityHash:attributes:)` | 유저 식별 |
| `subscribe(topic:token:)` | 토픽 구독 |
| `rotateToken(oldToken:newToken:identityHash:)` | 토큰 교체 |
| `unsubscribe(topic:token:)` | 토픽 구독 해지 |
| `Notikit.customData(fromPayload:)` | 받은 푸시 `userInfo` 에서 커스텀 필드(템플릿 필드 포함)만 꺼내기 |
| `Notikit.deepLink(fromPayload:)` | 받은 푸시의 딥링크 |

- `apiSecret` 은 서버 전용 — 앱에는 넣지 마세요.
- 유저 id 는 `userId:` 로 넘기고 서버에는 `user_id` 로 전송된다. 이전 이름 `externalId:`
  (`external_id`) 도 계속 동작하지만 deprecated 다 — 컴파일러가 `userId:` 로 바꾸라고 안내한다.
- 반환 타입은 전부 구체 타입(`NotikitDevice`, `Bool`, `Void`)이다. `[String: Any]` 는
  Sendable 이 될 수 없어 Swift 6 에서 막힌다.

## 라이선스
Apache-2.0

## 알림 탭 자동 보고

`UNUserNotificationCenter.delegate` 는 앱당 하나뿐이라 SDK 가 차지하면 앱(또는
Firebase)이 쓰던 델리게이트가 끊긴다. 그래서 가로채지 않고 **앞에 끼운다** — 우리가
먼저 클릭을 기록하고 원래 델리게이트로 그대로 넘긴다.

```swift
// Firebase 설정 이후에 호출해야 기존 델리게이트가 체인에 들어간다
let session = Notikit.installNotificationDelegate(client: notikit) { currentFcmToken }
```

토큰은 갱신되므로 값이 아니라 클로저로 넘긴다. 클릭 보고는 백그라운드로 띄우고
완료 핸들러를 붙잡지 않는다 — 붙잡으면 네트워크가 느릴 때 탭 반응이 늦어진다.

## 세션 — 로그인·토큰 교체·밀린 클릭

`installNotificationDelegate` 가 돌려주는 `NotikitSession` 이 유저 바인딩과 **클릭 큐**를
쥔다. 알림 탭은 네트워크가 없을 때 가장 많이 일어나므로, 재시도가 없으면 클릭률이
실제보다 낮게 집계된다. 실패한 보고는 큐에 남아 다음 실행 때 자동으로 재전송된다
(최대 50건, 7일 TTL, 4xx 는 즉시 폐기 — Android 와 같은 규칙).

```swift
try await session.login(user: NotikitStoredUser(userId: "user-1", identityHash: hash), token: token)
try await session.logout(token: token)

// 토큰이 갱신되면: 새 토큰으로 registerDevice 를 부르면 행이 하나 더 생겨
// 같은 사람에게 중복 발송된다. 교체는 전용 메서드를 쓴다.
try await session.rotateToken(oldToken: old, newToken: new)
```

탭 직후 홈으로 나가도 보고가 끊기지 않도록 짧은 배경 태스크를 잡는다.
