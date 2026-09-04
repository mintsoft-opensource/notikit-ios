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
