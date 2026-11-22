# 四指捏合手势系统优化方案

> 状态：方案稿（未实施）　｜　日期：2026-11-22　｜　范围：`Sources/LaunchXCore/Invoke/TrackpadTouchMonitor.swift`、`Sources/LaunchXCore/Launchpad/LaunchpadWindowController.swift`、`Sources/LaunchXCore/Launchpad/LaunchpadContentView.swift`、`Sources/LaunchXCore/App/AppDelegate.swift` 及对应测试

---

## 0. 摘要

当前捏合系统的总体方向是对的：走 MultitouchSupport 原始触点流，在识别器里用位移否决区分滑动和捏合，按识别器会话决定吞哪些系统帧，单指空闲帧不进主线程。本方案不推翻这条路线，主要修三类问题：

| 编号 | 问题 | 类别 | 优先级 | 改动面 |
|---|---|---|---|---|
| O1 | 不抬手反向、或捏合后整手漂移时，会被位移否决误取消 | 正确性 | P0 | 识别器 |
| O2 | 会话中第 5 指或拇指落下、抬起时，张开度跳变 | 正确性 | P0 | 识别器 |
| O3 | 松手瞬间的抬指滑移污染终值；短暂失触直接结束会话 | 正确性 | P0 | 识别器 |
| O4 | 睡眠唤醒后 MT 设备失效，手势入口静默失灵 | 健壮性 | P0 | 监视器 |
| O5 | 进度依赖手的大小与触控板长宽比 | 手感 | P1 | 识别器（需重新标定） |
| O6 | 提交只看位置、不看速度；落位动画速度不连续 | 手感 | P1 | 识别器 + 控制器 |
| O7 | 识别器在主线程运行，主线程拥塞时滑动否决滞后，四指滑动开头的帧被误吞 | 性能/正确性 | P2 | 监视器架构 |
| O8 | 时间源用系统时钟（可能跳变），帧时间戳被丢弃 | 健壮性 | P2（随 O7） | 识别器 / 抑制器 |
| O9 | 跟手期间每帧重算根视图 `body` | 性能 | P2 | 内容视图 |
| O10 | 只监听默认设备，不支持外接触控板热插拔 | 健壮性 | P3 | 监视器 |
| O11 | 零碎问题（重复调用、过期注释） | 清理 | 随手 | 控制器 / AppDelegate |

推荐分 4 批落地（见第 6 节），每批都能单独合入、单独回归。

---

## 1. 现状链路

```
MT 内部线程 (125Hz)                     主线程                               抑制 tap 专用线程
─────────────────────────              ────────────────────────────         ───────────────────
contactFrameCallback                   TrackpadTouchMonitor.ingest           suppressTapCallback
 ├─ 数 touching（state 3/4）            ├─ PinchTouchRecognizer.ingest        └─ type 30 且
 ├─ suppressor.note(≥4 → 临时武装)      │   ├─ 位移否决 → vetoed                  suppressor.isActive()
 ├─ shouldForwardMTFrame 过滤           │   ├─ 识别门 → began/pinchConfirmed      → 吞帧
 └─ DispatchQueue.main.async(samples) ─▶│   └─ changed / ended / cancelled
                                        ├─ suppressor.latchSwipe / confirmPinch / arm
                                        └─ onEvent → LaunchpadWindowController.handlePinchGesture
                                                      ├─ beginPinchGesture
                                                      ├─ model.pinchTransitionProgress = …（每帧）
                                                      └─ settlePinchGesture（|p| ≥ 0.5 提交）
```

关键阈值（`PinchTouchThresholds`）：`minContacts=4`、`movementFloor=0.06`、`vetoRatio=0.40`、`emitFloor=0.05`、`fullTrip=0.30`、`sessionCooldown=0.25s`、`suppressTail=0.10s`。

---

## 2. P0：识别器正确性（O1～O3）

这一批只改 `PinchTouchRecognizer`，阈值和对外接口都不变，风险最低、收益最直接。

### O1. 确认捏合后，位移否决改用峰值张开度

**问题**

[TrackpadTouchMonitor.swift:214](../Sources/LaunchXCore/Invoke/TrackpadTouchMonitor.swift) 每帧都用 `|spreadDelta| / maxFingerMove < 0.40` 判滑动，已确认、正在投递进度的会话也不例外。

- **中途反向**：用户捏合到一半再张开时，`spreadDelta` 会经过 0。只要此时有一指离落点超过 0.06（手整体漂移约 9mm，真机上很常见），比值就趋近 0，会话被判成滑动并 `cancelled`，面板弹回原状。这和控制器注释承诺的"过零连续翻转"相矛盾。
- **捏合后漂移**：捏到位后整手略微平移，`maxFingerMove` 继续增长，`spreadDelta` 不变，同样会被取消。

现有测试 `midSessionReversalCrossesZero` 没有暴露这个问题，因为合成的十字位手势围绕固定中心等比缩放：过零时每根手指恰好回到落点，`maxFingerMove == 0`。真机不会有这么理想的几何。

**方案**

- **过识别门之前**，判据保持不变，仍用当帧 `|spreadDelta|`。这一段的阈值是按实测标定的，滑动比值 0.10～0.21，必须保持原样。
- **过识别门之后**，判据中的分子改成会话内的峰值 `peakAbsDelta = max(|spreadDelta|)`：

```swift
// 新增会话状态
private var peakAbsDelta: Float = 0

// advanceSession 内
peakAbsDelta = max(peakAbsDelta, spreadDelta.magnitude)
let evidence = sessionEmitting ? peakAbsDelta : spreadDelta.magnitude
let ratio = evidence / max(maxFingerMove, 0.0001)
if maxFingerMove > PinchTouchThresholds.movementFloor, ratio < PinchTouchThresholds.vetoRatio {
    // …否决逻辑不变
}

// openSession / closeSession 中归零
peakAbsDelta = 0
```

**效果推演**

| 场景 | 旧逻辑 | 新逻辑 |
|---|---|---|
| 捏合到 peak=0.20 后反向过零，漂移 0.08 | 比值≈0 → 取消 ✗ | 0.20/0.08=2.5 → 继续 ✓ |
| 完整捏合后整手平移 | 平移超过约 2.5×当前 delta 就取消 | 平移超过约 2.5×peak 才取消，正常漂移不会触发 ✓ |
| 现有用例 `translationMidSessionDeliversCancelled`（peak≈0.116，平移到 0.39） | 取消 | 平移约 0.29 后取消，用例仍通过 ✓ |
| 三指滑动 + 拇指（过门前就被否决） | 否决 | 不变 ✓ |

**备选（暂不做）**：把每指位移拆成"质心平移 T"和"形变 D = 每指位移 − T"，改用 `D/|T|` 作判别式，物理含义更干净。代价是滑动/捏合的分界需要整体重新标定，留到 O5 标定时一并评估。

### O2. 会话成员固定 + 成员变化时平移基线

**问题**

`baselineSpread` 只在会话开启时算一次，之后每帧用"当前所有 touching 触点"的平均两两间距。所以：

- 会话中第 5 指或拇指落下，平均间距突变，进度跳一下，严重时还会触发否决；
- 五指开局、中途抬起一指（仍 ≥4）时同样会跳；
- `maxFingerMove` 也把新落下的触点算进去了（新触点原点就是落点，影响较小，但口径不一致）。

**方案**

1. 会话开启时记录成员集 `members: Set<Int32>`。之后计算张开度和位移时只用"仍在 touching 状态的成员"，会话中新落下的触点不参与。
2. 参与计算的成员子集（按 id 排序）和上一帧不同时，把基线平移到能让 delta 连续的位置：

```swift
private var members: Set<Int32> = []
private var activeKey: [Int32] = []     // 上一帧参与计算的成员 id（升序）
private var lastSpreadDelta: Float = 0

// advanceSession 开头
let active = touching.filter { members.contains($0.id) }.sorted { $0.id < $1.id }
guard active.count >= PinchTouchThresholds.minContacts else { return }   // 交给收尾逻辑
let key = active.map(\.id)
guard let raw = Self.spread(of: active) else { return }
if key != activeKey {
    // 成员子集变化：平移基线，使本帧 delta == 上一帧 delta（进度不跳变）
    baselineSpread = raw - lastSpreadDelta
    activeKey = key
}
let spreadDelta = raw - baselineSpread
lastSpreadDelta = spreadDelta
// maxFingerMove 同样只遍历 active
```

   会话开启时同步初始化 `members`、`activeKey = 成员 id 升序`、`lastSpreadDelta = 0`。否则第一帧 `advanceSession` 会把 `activeKey` 从空数组改成成员集而误触发一次平移，吞掉首帧的位移。

3. 第 4 步"会话收尾"的判断从"touching 数 < 4"改成"**成员中**仍 touching 的数 < 4"。这样，四指会话里第 5 指的落下或抬起都不会影响会话的生死。

**注意**

- 开局时成员原点重置的逻辑（[TrackpadTouchMonitor.swift:175](../Sources/LaunchXCore/Invoke/TrackpadTouchMonitor.swift)）保留，只作用于成员。
- 抑制侧 `GestureSuppressor.note(touchingCount:)` 仍按原始触点数临时武装，不受影响。

### O3. 松手终值去尾 + 短暂失触宽限

**问题 A：抬指滑移**

松手是逐指抬起的。抬起过程中接触面缩小、质心偏移，最后几帧的张开度会往回掉，`ended` 携带的 `lastProgress` 因此偏小，本来过半的捏合可能落到 0.5 以下，被判为回退。

**问题 B：短暂失触**

四指中有一指的状态抖动一两帧（离开 3/4 再回来），会话立刻 `ended`，接着进入 0.25s 冷却，用户感觉"手势断了"。

**方案 A：进度历史环形缓冲**

```swift
private struct ProgressSample { let t: TimeInterval; let p: CGFloat }
private var history: [ProgressSample] = []      // 只保留最近 ~150ms，上限约 20 帧

// 每次投递 changed 时追加，并淘汰 now-0.15 之前的样本
// ended 终值：取 now - releaseTrim 时刻之前最近的一个样本
static let releaseTrim: TimeInterval = 0.024     // ≈3 帧，覆盖抬指滑移
```

- `ended` 的 `signedProgress` 改为"松手前 24ms 处的进度"。历史不足时退回 `lastProgress`。
- 不用"峰值保持"：用户在最后时刻主动往回收（想取消）时，峰值会把取消误判成提交；去尾取值没有这个偏差。
- O6 的速度估计复用同一个缓冲（窗口同样去尾）。

**方案 B：失触宽限**

```swift
private var belowSince: TimeInterval?
static let dropoutGrace: TimeInterval = 0.024

// 收尾逻辑
let memberTouching = touching.filter { members.contains($0.id) }.count
let explicitLift = samples.contains { members.contains($0.id) && $0.state >= 5 }
if memberTouching < minContacts {
    if explicitLift { endSession() }                       // 明确抬指（breakTouch 及之后）：立即结束
    else if let since = belowSince, now - since >= dropoutGrace { endSession() }
    else if belowSince == nil { belowSince = now }         // 进入宽限，本帧不投递、不否决
} else {
    belowSince = nil
}
```

- 宽限期间 `outcome.sessionActive` 仍为 true，抑制窗口继续续期。
- **需要真机确认**：失触时 MT 报出的状态序列是"直接从帧里消失"，还是同样走 5→6→7。如果失触也会出现 state 5，`explicitLift` 就无法区分两者，宽限只能纯按时间判断，代价是所有松手都多出 24ms 的落位延迟（可以接受）。用 `LAUNCHX_TOUCH_TRACE=1` 采 10 次失触样本确认。

### O4. 睡眠唤醒后重启 MT 设备（放进 P0，因为改动小、收益大）

**问题**

全库只有 `applicationWillTerminate` 会调用 `gestureMonitor.stop()`，没有任何唤醒处理。MT 设备在系统睡眠、唤醒或切换用户之后经常不再回调，手势入口会静默失灵，只能重启 App 恢复。

**方案**（`TrackpadTouchMonitor` 内部自理，AppDelegate 不用改）

```swift
private var wakeObservers: [any NSObjectProtocol] = []

private func observeSystemWake() {
    guard wakeObservers.isEmpty else { return }
    let nc = NSWorkspace.shared.notificationCenter        // 注意：必须用 NSWorkspace 的通知中心
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
        wakeObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // 唤醒后设备未必立即就绪：延迟 1s 重启
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.restart()
                }
            }
        })
    }
}
```

- 在 `restart()` 末尾调用 `observeSystemWake()`。`stop()` 里不要移除这些观察者，否则下次唤醒就监听不到了；只在 `setEnabled(false)` 时移除。
- `stop()` 时如果识别器正在投递，补发一个 `.cancelled`，避免控制器卡在半途的跟手状态（`pinchStartVisible` 不为 nil）。为此要给识别器新增 `func abort() -> [PinchGestureEvent]`。

### P0 测试清单（`PinchTouchRecognizerTests`）

| 用例 | 构造 | 断言 |
|---|---|---|
| `reversalWithDriftIsNotVetoed` | 用比十字位更大的跨度（偏移 0.12）：先捏拢到 k=0.5，再张开到 k=1.4，全程质心每帧漂移 +0.004 | 没有 `cancelled`；末事件是 `ended`；**用旧代码跑必须失败**（先写测试、确认红灯，再改实现） |
| `translationAfterSmallPinchStillCancels` | 保留现有 `translationMidSessionDeliversCancelled` | 仍以 `cancelled` 结束 |
| `fifthFingerLandingKeepsContinuity` | 四指捏合中途，在远角落下 id=5 并保持 | 相邻 `changed` 差值 < 0.1；不出现 `cancelled` |
| `memberLiftInFiveFingerSessionRebases` | 五指开局，中途一指 state 5 后消失，剩余四指继续捏合 | 进度连续；会话不结束 |
| `endedProgressTrimsLiftSlip` | 捏合到 0.6 后，最后 3 帧张开度回落到 0.45 再离板 | `ended.signedProgress ≈ 0.6`（误差 < 0.05） |
| `briefDropoutWithinGraceContinues` | 一指连续 2 帧（16ms）缺失后恢复，状态不是 5 | 没有 `ended`；后续 `changed` 正常 |
| `dropoutBeyondGraceEnds` | 一指缺失超过 24ms | `ended` |
| `abortDeliversCancelledWhenEmitting` | 投递中调用 `abort()` | 返回 `[.cancelled]`；未投递时返回空 |

---

## 3. P1：手感（O5、O6）

### O5. 长宽比校正 + 相对进度

**问题**

1. MT 的归一化坐标 x、y 都在 0～1，但触控板不是正方形。以 Force Touch 触控板为例，宽高比约为 1.4:1，同样的物理距离，竖直方向的归一化数值更大。因此斜向捏合和横向捏合得到的张开度不同，**否决比值也带着方向偏差**。
2. `fullTrip=0.30` 是绝对量。手小、或起手手指就并得比较拢的用户，捏到底也只能让张开度减少"起手张开度 − 最小间距"，可能永远摸不到 0.5 的提交线。反过来，大手轻轻一捏就满行程。

**方案**

1. **长宽比校正**：通过 dlsym 加载 `MTDeviceGetSensorSurfaceDimensions(MTDeviceRef, int32_t *width, int32_t *height)`（社区逆向的签名，单位通常为 0.01mm，**需要本机探针验证**），启动设备时读一次：

```swift
// MultitouchBridge 新增（可选符号：缺失时 aspect = 1，不影响启用）
let getDimensions: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32)?

// MT 回调解析样本时：y 换算到「宽度单位」
let yScaled = y * aspect      // aspect = height / width，约 0.7
```

   换算后 x 方向的数值不变，所以以横向为主的标定数据基本还能用；但否决比值和 `emitFloor` 都要用新口径的 trace 重新验证（见第 7 节）。

2. **相对进度**：识别门（`emitFloor`）继续用绝对量，因为它针对的是绝对噪声；跟手进度改用对数比例：

```swift
// r = 当前张开度 / 会话基线张开度
// 捏拢（r<1）→ 正进度（展开面板）；张开（r>1）→ 负进度（收起面板）
static let fullRatioIn:  Float = 0.55   // 捏拢到起手的 55% 视为满行程（待标定）
static let fullRatioOut: Float = 1.80   // 张开到起手的 180% 视为满行程（待标定）

func relativeProgress(current: Float, baseline: Float) -> CGFloat {
    guard baseline > 0.05 else { return absoluteProgress(...) }   // 基线过小：退回绝对口径
    let r = current / baseline
    if r < 1 { return  CGFloat(min(log(1 / r) / log(1 / fullRatioIn), 1)) }
    else     { return -CGFloat(min(log(r) / log(fullRatioOut), 1)) }
}
```

   - 对数让捏拢和张开在感知上对称，过零时斜率连续（O1 的反向场景依旧平滑）。
   - O2 平移基线的做法也要同步改成乘性：`baseline = raw / currentRatio`。

**风险**：这一项会改变所有用户的手感，必须完成标定（第 7 节），并在合入前拿至少两种手型实测。

### O6. 速度参与提交 + 落位动画接续速度

**问题**

- [shouldCommitPinch](../Sources/LaunchXCore/Launchpad/LaunchpadWindowController.swift) 只看 `|p| ≥ 0.5`。快速短捏（|p| 只有 0.3，但速度很快）不会提交；系统启动台和 iOS 交互式转场都会把"快甩"当作提交意图。
- 落位用不带初速度的 `.spring(duration: 0.3, bounce: 0.12)`。松手时内容正在高速运动，动画却从速度 0 起步，有一下明显的顿挫。

**方案**

1. **事件携带速度**。给 `PinchGestureEvent` 加字段，带默认值以保持源码兼容：

```swift
public struct PinchGestureEvent: Sendable {
    public let phase: PinchGestureEventPhase
    public let signedProgress: CGFloat
    /// 有符号进度的变化速度（进度/秒），已去尾；仅 changed / ended 有意义。
    public let velocity: CGFloat
    public init(phase: PinchGestureEventPhase, signedProgress: CGFloat, velocity: CGFloat = 0) { … }
}
```

   速度估计：在 O3 的历史缓冲上，取 `[now − 24ms − 64ms, now − 24ms]` 窗口做最小二乘斜率（约 8 个样本，比首尾差分更抗抖）。`dt` 优先用 MT 帧时间戳（见 O8）。

2. **提交判定**：

```swift
static let flingVelocity: CGFloat = 1.5      // 进度/秒（满行程约 250ms ≈ 4/s，待标定）
static let flingMinProgress: CGFloat = 0.15

nonisolated static func pinchSettleTarget(progress p: CGFloat, velocity v: CGFloat,
                                          cancelled: Bool, startVisible: Bool) -> Bool {
    guard !cancelled else { return startVisible }
    if abs(v) >= flingVelocity, abs(p) >= flingMinProgress {
        // 快甩：按速度方向决定。往零点方向甩 = 用户想撤回 → 回到起点
        return p * v > 0 ? (p > 0) : startVisible
    }
    return abs(p) >= 0.5 ? (p > 0) : startVisible
}
```

   用它替换 `shouldCommitPinch` 和 `targetVisible` 的两步计算（纯函数，便于测试）。

3. **落位动画接续速度**：

```swift
let current = model.pinchTransitionProgress ?? (startVisible ? 1 : 0)
let target: Double = targetVisible ? 1 : 0
let animation: Animation
if reduceMotion {
    animation = MotionPreference.panelTransition(reduceMotion: true)
} else {
    // SwiftUI 的 initialVelocity 以「剩余距离/秒」为单位
    let distance = target - current
    let toward = abs(distance) > 0.02 ? Double(velocity) / distance : 0
    animation = .interpolatingSpring(duration: 0.3, bounce: 0.12,
                                     initialVelocity: min(max(toward, 0), 8))
}
withAnimation(animation, update)
```

   - 视觉进度等于"起点 + 有符号进度"，所以视觉速度就等于 `velocity`，不需要换算。
   - 速度背离目标时取 0（不会先往反方向冲一下）；上限 8 防止过冲。
   - `hideSettleDelay = 0.4` 继续适用（同样的 duration 和 bounce）。

**测试**

- `PinchGestureTests` 补充 `pinchSettleTarget` 真值表：慢速过半、慢速不过半、快甩短捏、反向快甩、cancelled。
- 识别器：匀速捏合 N 帧后 `ended.velocity` 与理论值误差 < 10%；末尾 3 帧滑移不影响速度。
- 落位速度换算抽成纯函数 `settleInitialVelocity(current:target:velocity:)`，测边界：距离≈0、速度背离、超上限。

---

## 4. P2：线程架构与渲染（O7～O9）

### O7. 识别器下沉到 MT 线程 + 事件合并

**问题**

- 吞帧决策链跨了两个线程：MT 线程看到 ≥4 触点就先临时武装，但"判成滑动、立即放行"要等主线程处理完这一帧才发生。主线程拥塞时（翻页动画、首次展开渲染、壁纸捕获回调），积压窗口内的 type 30 帧都会被吞。**设置成四指滑动切空间的用户，开头的切换手势可能迟钝甚至失效。**
- 主线程积压后会一次性处理多帧，每帧都写一次 `pinchTransitionProgress`，产生无效渲染。

**方案**

识别器是纯状态机，没有 UI 依赖，可以直接在 MT 回调线程上同步运行：

```swift
/// 只在 MT 回调线程访问（MT 对同一设备的回调串行）。每次 startDevice 新建，天然完成状态重置。
final class TouchPipeline: @unchecked Sendable {
    let recognizer = PinchTouchRecognizer()      // 去掉 @MainActor
    var lastForwardedTouching = 0
}

/// MT 线程投递、主线程取走。连续的 changed 合并为最新一条（速度已在事件内，合并不损失信息）。
final class PinchEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [PinchGestureEvent] = []
    private var drainScheduled = false

    /// 返回 true 表示调用方需要调度一次主线程 drain。
    func post(_ events: [PinchGestureEvent]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for e in events {
            if e.phase == .changed, let last = pending.last, last.phase == .changed {
                pending[pending.count - 1] = e
            } else {
                pending.append(e)
            }
        }
        guard !pending.isEmpty, !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    func drain() -> [PinchGestureEvent] {
        lock.lock(); defer { lock.unlock() }
        drainScheduled = false
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
```

MT 回调改成：

```swift
// …解析 samples（单指空闲帧仍然短路）
let now = GestureClock.now()
let outcome = pipeline.recognizer.ingest(samples, now: now)
if outcome.vetoed { suppressor.latchSwipe() }
else if outcome.pinchConfirmed { suppressor.confirmPinch(now: now) }
if outcome.sessionActive { suppressor.arm(now: now) }
if mailbox.post(outcome.events) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard let monitor = TrackpadTouchMonitor.activeMonitor else { return }
            for e in mailbox.drain() { monitor.onEvent?(e) }
        }
    }
}
```

**要点**

- **生命周期**：`activeMonitor` 和 `pipeline` 的静态引用会在 MT 线程与主线程之间竞争（`stop` 时）。改用 `OSAllocatedUnfairLock<TouchPipeline?>` 保护：MT 回调取一次快照后使用；`stopDevice` 先调用 `MTDeviceStop`，再把引用置空。
- **MT 线程上的开销**：识别器每帧做 O(n²) 的张开度计算（n ≤ 10），可以忽略。要避免的是每帧分配内存：`touching` 过滤、`updated` 字典都可以改成复用缓冲（可选优化，先用 Instruments 的 Allocations 量一下再决定）。trace 本来就在 MT 线程写，不受影响。
- **测试入口**：现在 `TrackpadTouchMonitor.ingest(_:now:)` 是测试直接驱动的入口。改为 `nonisolated func ingestForTesting(_:now:) -> IngestOutcome`，内部同步走 pipeline、写抑制器，并把事件直接交给 `onEvent`（测试在主线程调用）。现有抑制相关测试改调用名即可。
- `PinchTouchRecognizerTests` 上的 `@MainActor` 可以保留（识别器去掉隔离后，在任何线程调用都可以）。
- `shouldForwardMTFrame` 的语义从"是否转发到主线程"变成"是否运行识别器"，测试保持不变。
- 新增 `PinchEventMailbox` 的单测：连续 changed 只留最新一条；began、ended、cancelled 不合并、保持顺序；已调度 drain 时不重复调度。

### O8. 统一单调时钟

**问题**

识别器的冷却期、抑制器的吞帧窗口、tap 回调的 `isActive()` 都用 `Date().timeIntervalSince1970`。这是系统时钟，NTP 校时或用户手动改时间时会跳变，可能导致吞帧窗口卡住（时间回拨）或冷却期失效。MT 回调第 4 个参数给的帧时间戳目前被丢弃。

**方案**

```swift
enum GestureClock {
    /// 单调时钟（mach 绝对时间，开机起算，不受校时影响）。识别器、抑制器、tap 回调共用。
    @inline(__always) static func now() -> TimeInterval { CACurrentMediaTime() }
}
```

- 把 `GestureSuppressor` 所有方法的默认参数 `Date().timeIntervalSince1970` 换成 `GestureClock.now()`。测试都显式注入了 `now` 或者只看相对关系，不受影响；`provisionalArmFromMTThread` 用的是默认参数，两端时钟一致即可。
- 速度估计（O6）的 `dt` 用 MT 帧时间戳，消除回调调度抖动。**需要探针确认**帧时间戳的基准（推测是开机起算的秒数，和 `CACurrentMediaTime()` 同源）。同源时，识别器的 `now` 可以直接取帧时间戳；不同源时，只用它来算 `dt`。
- trace 日志的时间戳继续用系统时钟，方便和系统日志对照。

### O9. 跟手进度不再触发根视图重算

**问题**

[LaunchpadContentView.swift:125](../Sources/LaunchXCore/Launchpad/LaunchpadContentView.swift) 的 `transitionProgress` 在根视图的 `body` 里读 `model.pinchTransitionProgress`，`.allowsHitTesting(... && model.pinchTransitionProgress == nil)` 也读了它。Observation 因此把根 `body` 登记为这个属性的依赖：跟手期间每帧（最高 125Hz）都会重跑整个根 `body`，包括 `content` 里的 GeometryReader、多个 `onChange`、`onPreferenceChange` 等。

**方案 A（推荐）：拆出过渡容器**

```swift
/// 只有这个容器读跟手进度：每帧重算范围限定在它的 body。
struct PanelTransitionContainer<Background: View, Content: View>: View {
    let model: LaunchpadModel
    let reduceMotion: Bool
    @ViewBuilder let background: Background
    @ViewBuilder let content: Content

    var body: some View {
        let p = model.pinchTransitionProgress ?? (model.isVisible ? 1 : 0)
        ZStack {
            background.opacity(p)
            content
                .scaleEffect(MotionPreference.contentScale(progress: p, reduceMotion: reduceMotion))
                .opacity(p)
        }
    }
}
```

- 根 `body` 不再读 `pinchTransitionProgress`。
- 命中测试改读一个**只在手势开始和结束时变化**的布尔值：给模型加 `public private(set) var isPinchInteracting = false`，由控制器在 `beginPinchGesture` 和 `settlePinchGesture` 里设置；根视图改为 `.allowsHitTesting(model.isVisible && !model.isPinchInteracting)`。
- `.animation(…, value: model.isVisible)` 保留在根上（只在可见性变化时触发）。

**验证方法（必须做，不凭推断合入）**

1. 临时在 `LaunchpadContentView.body`、`PagedGridArea.body`、`PageGridView.body` 里加 `let _ = Self._printChanges()`，捏合过程中观察输出：前者每帧应该**不再出现**，后两者应该接近 0 次。
2. 用 Instruments 的 SwiftUI 模板（View Body / View Properties）对比改动前后，一次 1 秒捏合中各视图 body 的调用次数。
3. 如果发现 `content` 作为不可比较的值（含闭包）仍会被逐帧重算，再考虑方案 B。

**方案 B（兜底）：图层直驱**

跟手期间不经过 SwiftUI，控制器直接设置 hosting view 背景层和内容层的 `opacity` 和 `transform`（用 `CATransaction.setDisableActions(true)`）；松手后再交回 SwiftUI 驱动落位。前提是背景和内容拆成两个 hosting view，或者能稳定拿到对应的 CALayer，改动面较大，只有方案 A 不达标时才做。

**可选：按显示刷新率合并**

O7 的 mailbox 已经把积压合并掉了。如果 125Hz 输入在 60Hz 屏上仍然过多（每帧 2 次写入），可以在控制器里缓存最新进度，用 `NSView.displayLink(target:selector:)` 每个显示帧只写一次模型。先测再决定。

---

## 5. P3：多设备与热插拔（O10）

**问题**

只用了 `MTDeviceCreateDefault`，拿到的是内建触控板（或系统选定的默认设备）。外接 Magic Trackpad、或者合盖外接显示器只用外置触控板的场景下，手势完全不可用；运行中插拔也不会感知。

**方案**

1. 通过 dlsym 加载 `MTDeviceCreateList`（返回 `CFArrayRef` 设备列表），对每个设备注册回调并启动。
2. MT 回调的第 1 个参数就是设备指针：`[设备指针: TouchPipeline]` 字典在 `start` 时一次性建好，运行期只读，所以不需要加锁。**每个设备一个识别器**，避免两块板的触点混在一起；抑制器全局共享，任何一个设备的会话都可以武装它。
3. **热插拔**：注册 IOKit 匹配通知（`IOServiceAddMatchingNotification`，监听首次匹配和终止两种事件）。服务类名用 `ioreg -l | grep -i multitouch` 在本机确认，候选是 `AppleMultitouchDevice`。通知到达后防抖 1s，再调用 `restart()`。
4. `isAvailable()` 只针对默认设备做判断，改为"设备列表非空"。

**测试**：这一项主要靠真机验证（内建 + 外接、插拔、合盖），单元层只测"多 pipeline 互不串扰"：两组 id 相同但来源设备不同的帧交替注入，各自识别。

---

## 6. 零碎问题（O11，随手处理）

| 位置 | 问题 | 处理 |
|---|---|---|
| [LaunchpadWindowController.swift](../Sources/LaunchXCore/Launchpad/LaunchpadWindowController.swift) `beginPinchGesture` | `removeAutoHideMonitors()` 调用了两次（开头一次，`ignoresMouseEvents` 之前又一次） | 删掉第二次 |
| [AppDelegate.swift](../Sources/LaunchXCore/App/AppDelegate.swift) `setupStatusItem` | 注释说"手势只有拿到辅助功能权限才算有效入口"，但 `isEntryAvailable` 现在不依赖权限 | 更新注释 |
| `TrackpadTouchMonitor` 静态属性注释 | `suppressor` 的注释仍写着"≥3 触点抑制窗口" | 改成"捏合会话驱动的抑制窗口" |

---

## 7. 标定流程（O5、O6 的前置条件，O1 回归时也建议跑一遍）

### 7.1 扩展 trace 字段

在现有 `LAUNCHX_TOUCH_TRACE=1` 的基础上增加会话级日志：

```
SESSION-OPEN members=1,2,3,4 baseline=0.312 aspect=0.70
SESS t=… n=4 spread=0.281 delta=-0.031 peak=0.031 move=0.024 ratio=1.29 p=0.18 v=2.4 emit=1
SESSION-END reason=lift|veto|dropout|abort final=0.62 v=3.1
```

### 7.2 采集样本（每类各录一份 trace，文件名带标签）

| 标签 | 次数 | 说明 |
|---|---|---|
| `pinch-in` | 20 | 四指捏合，慢、中、快各占约 1/3 |
| `spread-out` | 20 | 四指张开 |
| `reverse` | 10 | 捏到一半不抬手反向 |
| `fling` | 10 | 快速短捏（期望提交） |
| `swipe3-thumb` | 20 | 三指滑动 + 拇指搭板（期望全程否决） |
| `swipe4-space` | 20 | 四指滑动切空间（期望否决，且系统切换正常） |
| `dropout` | 10 | 捏合中某指轻微离板（用于 O3 宽限） |

至少两名手型差异明显的用户分别采集。

### 7.3 分析脚本

新增 `scripts/analyze-touch-trace.py`（纯标准库），按标签输出：

- 过门前的否决比值分布（滑动类 vs 捏合类）→ 确认 `vetoRatio` 的分离余量，O5 换口径后重新取中点；
- 起手基线张开度分布、满行程比例 `r` 的分布 → 定 `fullRatioIn` / `fullRatioOut`（取能让 80% 正常捏合达到满行程的值）；
- 松手前速度分布（`fling` vs 慢速）→ 定 `flingVelocity`；
- 失触的状态序列 → 确认 O3 的 `explicitLift` 判据是否成立。

标定结果连同数据摘要写回 `PinchTouchThresholds` 的注释（保持现有"实测区间 + 取值理由"的风格）。

---

## 8. 实施批次

| 批次 | 内容 | 前置 | 预计改动 | 验收 |
|---|---|---|---|---|
| **第 1 批（P0）** | O1、O2、O3、O4、O11 | 无（O3 的宽限判据需要少量失触 trace） | 识别器约 120 行，监视器约 40 行，新增测试约 8 个 | 全部单测通过；真机：反向捏合不再被取消；捏合中拇指落板不跳；合盖睡眠唤醒后手势仍然可用 |
| **第 2 批（P2）** | O7、O8、O9 | 第 1 批 | 监视器重构约 150 行，内容视图约 40 行 | 单测通过；真机：翻页动画进行中做四指滑动切空间，系统切换不受影响；`_printChanges` / Instruments 确认根 body 不再逐帧重算 |
| **第 3 批（P1）** | O5、O6 | 第 7 节标定完成；O8 的帧时间戳确认 | 识别器约 80 行，控制器约 40 行，事件结构 +1 字段 | 单测通过；两种手型实测：轻捏能达到提交线、快甩能提交、落位无顿挫 |
| **第 4 批（P3）** | O10 | 第 2 批（pipeline 化） | 桥接约 60 行，监视器约 80 行 | 真机：内建板 + 外接板分别可用；插拔后自动恢复 |

把 P2 排在 P1 之前，是因为 O7 把识别器移到 MT 线程、O8 统一时钟之后，O6 的速度估计才能用上稳定的帧时间戳；先做 P1 的话，速度相关代码要返工一次。

---

## 9. 风险与回退

| 风险 | 影响 | 缓解 |
|---|---|---|
| O1 放宽否决后，"小捏合 + 大平移"的边界变化 | 少数滑动在过识别门之后不再被取消 | 过门前的判据完全不变，滑动在过门前就被拦下（实测滑动比值 ≤ 0.21，过门需要 delta ≥ 0.05，即位移 ≥ 0.24 才可能过门，而位移 > 0.06 时就已经被否决） |
| O5 改变进度口径 | 所有用户的手感都会变 | 必须先完成第 7 节标定；阈值集中在 `PinchTouchThresholds`，可以快速回滚 |
| O7 在 MT 线程上运行业务逻辑 | 识别器出现异常或耗时会拖慢 MT 回调 | 识别器无 I/O、无锁竞争（只有抑制器的短临界区）；Instruments 的 Time Profiler 确认单帧 < 50µs |
| O7 生命周期竞争 | `stop` 与回调并发时访问到已释放的 pipeline | 用锁保护快照引用，先 `MTDeviceStop` 再置空；pipeline 是 class，快照持有强引用，回调期间不会被释放 |
| 私有符号（`MTDeviceGetSensorSurfaceDimensions`、`MTDeviceCreateList`）在新系统缺失 | O5 长宽比 / O10 多设备不可用 | 一律按可选符号处理：缺失时退化为 aspect=1、只用默认设备，不影响主流程 |
| O9 方案 A 收益不达预期 | 渲染开销仍偏高 | 先用 Instruments 量化；不达标再上方案 B |

每一批都单独提交，出问题时可以按批 revert；阈值类改动和结构类改动不放在同一个提交里。
