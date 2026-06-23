先说一个最关键的设计点,它决定了整个方案的成败:**Bonjour 只负责"找到",绝不负责"信任"**。mDNS 在局域网里是无认证、可伪造的,任何人都能广播一个假的 `_polar-cp._tcp`。所以发现层只用来定位候选控制面,所有信任必须由一个攻击者拿不到的共享秘密来建立——也就是你说的 token。

## 1. 服务广播 / TXT

控制面用 `NWListener` 广播 `_polar-cp._tcp`,TXT 里放定位元数据(注意别放敏感信息,LAN 上人人可见):

- `cid`:集群 ID,区分多控制面、防误连
- `fp`:控制面公钥指纹(截断 SHA-256, base64url),做连接 pin 的提示
- `enr`:enrollment 端点,如 `/v1/enroll`
- `v` / `api`:协议、API 版本,做兼容门槛

新节点用 `NWBrowser` 浏览,按 `cid` 过滤掉无关广播。也可以让未入网节点反向广播 `_polar-node._tcp`,这样你的 CLI 能直接看到"有台新机器冒出来了",做半零接触纳管。

## 2. 引导信任 + 发 token(核心)

```
节点发现 CP → TLS 连接(pin fp) → 用 bootstrap token 跑 PAKE
  ↳ SPAKE2+/CPace:token 可以短(可手输/二维码),但在线只能猜一次
  ↳ 双向认证:节点确认这是真 CP(防 mDNS 伪造),CP 确认节点持有 token
信道建立后(绑定 TLS exporter 做 channel binding):
  节点提交 → SEP attestation + 硬件标识 + 本地生成的 NKey 公钥 / CSR
  CP 验证 attestation → 判定 trust tier → 签发凭据
```

**别用裸 bearer token 走 TLS**。一旦 pin 被绕过就是明文泄露。PAKE 的好处是 token 低熵也安全,且天然做到双向认证,正好挡住 mDNS 欺骗。裸 bearer + 指纹 pin 只能作为图省事的退路。

## 3. 签发的"token"建议直接用 NATS User JWT

这套和你的 NATS/JetStream 栈完美契合:节点本地生成 NKey(seed 永不出设备),CP 用 account 签名密钥签一个 User JWT,把权限(subject 读写、JetStream 配额)按 trust tier 收紧。`nats-server` 能拿 account 公钥**离线验证**,不需要回调。同一次 enrollment 响应里可以一起下发:NATS creds、短期 mTLS 证书、以及 WireGuard peer 配置(把入网三件事合并)。

两类 token 要分清:
- **bootstrap token**(你"发"出去纳管的那个):单次/限次、分钟级 TTL、最好每节点一个、可吊销。`polar enroll new --tier 1 --ttl 10m`
- **签发凭据**(节点拿到手的):NATS JWT 中期 TTL + 续签,或走 SPIFFE 式短证书自动轮换

## 4. 几个会咬人的坑

- **Apple 权限**:iOS 14+ / 加固的 macOS app 浏览或广播 Bonjour 需要 `com.apple.developer.networking.multicast` 授权(要向 Apple 申请),还有 `NSLocalNetworkUsageDescription` + 本地网络隐私弹窗。**无头 launchd daemon 弹不出这个授权框**,headless 纳管在 macOS 上有摩擦——你的 dev-fused 板子可能能绕过,量产机要提前验证。
- **跨子网**:mDNS 不过路由。多子网下要么补 unicast DNS-SD,要么用 NATS leafnode / 静态 seed 兜底。真要做设备云这条必须解决。
- 用 `NWListener` / `NWBrowser`,别碰老的 `NSNetService`。Linux 侧用 Avahi,服务类型保持一致就能跨平台互发现。

## 5. 发现层骨架(Network.framework)

```swift
import Network

// 控制面广播
let txt = NWTXTRecord(["v":"1","cid":clusterID,"fp":cpKeyFP,"enr":"/v1/enroll"])
let listener = try NWListener(using: .tls(tlsOptions), on: 8443)
listener.service = .init(name: "polar-cp-\(nodeID)",
                         type: "_polar-cp._tcp", txtRecord: txt.data)
listener.newConnectionHandler = { conn in /* PAKE → attest → 签 JWT */ }
listener.start(queue: .main)

// 节点发现
let browser = NWBrowser(for: .bonjourWithTXTRecord(type:"_polar-cp._tcp", domain:nil),
                        using: .init())
browser.browseResultsChangedHandler = { results, _ in
    for r in results {
        if case let .bonjour(txt) = r.metadata, txt["cid"] == expectedClusterID {
            // 候选控制面 → 发起 TLS+PAKE 引导
        }
    }
}
browser.start(queue: .main)
```

要的话我直接把完整的 enrollment daemon 写成一个 Swift 文件给你:`NWListener` 服务端 + SPAKE2+ 握手 + SEP nonce 验签 + 按 tier 签 NATS User JWT 的完整骨架。你倾向于 bootstrap 用 PAKE 还是先上裸 bearer+pin 的简化版?
