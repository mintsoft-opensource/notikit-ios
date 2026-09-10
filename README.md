# Notikit (Swift)

> Notikit Swift SDK — 유저 중심 푸시 디바이스 등록/식별 (async/await).

## 설치 (SPM)
```swift
.package(url: "https://github.com/notikit/notikit-swift", from: "0.1.0")
```
CocoaPods: `pod 'Notikit'`

## 사용
```swift
import Notikit

let notikit = Notikit(baseUrl: "https://push.example.com", apiKey: "nk_xxx") // 공개키만

// APNs/FCM 토큰 획득 후
try await notikit.registerDevice(
    token: fcmToken,
    platform: "ios",
    externalId: "user-123",
    identityHash: "<서버계산 HMAC>"
)
```

## API
| | 설명 |
|---|---|
| `registerDevice(token:platform:externalId:identityHash:...)` | 토큰 등록 |
| `identify(externalId:identityHash:attributes:)` | 유저 식별 |
| `subscribe(topic:token:)` | 토픽 구독 |

- `apiSecret` 은 서버 전용 — 앱에는 넣지 마세요.

## 라이선스
Apache-2.0

## 알림 탭 자동 보고

`UNUserNotificationCenter.delegate` 는 앱당 하나뿐이라 SDK 가 차지하면 앱(또는
Firebase)이 쓰던 델리게이트가 끊긴다. 그래서 가로채지 않고 **앞에 끼운다** — 우리가
먼저 클릭을 기록하고 원래 델리게이트로 그대로 넘긴다.

```swift
// Firebase 설정 이후에 호출해야 기존 델리게이트가 체인에 들어간다
Notikit.installNotificationDelegate(client: notikit) { currentFcmToken }
```

토큰은 갱신되므로 값이 아니라 클로저로 넘긴다. 클릭 보고는 백그라운드로 띄우고
완료 핸들러를 붙잡지 않는다 — 붙잡으면 네트워크가 느릴 때 탭 반응이 늦어진다.
