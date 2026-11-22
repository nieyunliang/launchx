import CoreGraphics
import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 捏合手势开关（旧档位迁移）

struct PinchGestureTests {

    /// 旧版档位字符串迁移为开关：off → 关，其余档位 → 开（统一按四指识别）。
    @Test func decodingLegacySettingsMigratesModesToToggle() throws {
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"pinchGesture":"off"}"#.utf8))
        #expect(off.pinchGestureEnabled == false)

        for legacy in ["threeFinger", "fourFinger", "fourFiveFinger", "fiveFinger"] {
            let json = #"{"pinchGesture":"\#(legacy)"}"#
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            #expect(decoded.pinchGestureEnabled == true, "legacy mode \(legacy)")
        }
    }

    /// 新开关沿用旧 JSON 键「pinchGesture」往返存档。
    @Test func toggleRoundTripsUnderLegacyKey() throws {
        #expect(AppSettings().pinchGestureEnabled == true)  // 默认开启
        let encoded = try JSONEncoder().encode(AppSettings())
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""pinchGesture""#))
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: encoded)
        #expect(roundTripped.pinchGestureEnabled == true)

        let disabled = AppSettings(pinchGestureEnabled: false)
        let disabledData = try JSONEncoder().encode(disabled)
        let decodedDisabled = try JSONDecoder().decode(AppSettings.self, from: disabledData)
        #expect(decodedDisabled.pinchGestureEnabled == false)
    }
}

// MARK: - 捏合手势的视觉进度（回归：收起闪烁、不抬手反向闪烁）

/// 视觉过渡进度口径为 0=收起、1=展开（内容视图 transitionProgress）。
/// 映射 = 会话起点可见性 + 有符号进度（张开为正、捏合为负），钳制 0...1：
/// - 收起会话识别瞬间保持展开态（不闪烁到 0）；
/// - 会话中途反向（不抬手捏合后再张开）过零天然连续，不弹回起点再塌缩。
@Suite
struct PinchVisualProgressTests {

    /// 展开会话（起点收起）：张开正进度从 0 生长；中途捏合钳在收起态 0。
    @Test func expandingSessionGrowsFromZero() {
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: false, signedProgress: 0) == 0)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: false, signedProgress: 0.4) == 0.4)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: false, signedProgress: 1) == 1)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: false, signedProgress: -0.4) == 0)
    }

    /// 收起会话（起点展开）：捏合从 1 收缩；中途张开平滑回满后钳在 1。
    @Test func collapsingSessionShrinksFromOne() {
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: true, signedProgress: 0) == 1)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: true, signedProgress: -0.4) == 0.6)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: true, signedProgress: -1) == 0)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: true, signedProgress: 0.4) == 1)
    }

    /// 反向过零连续：±ε 在过零两侧衔接（两个起点方向都不跳变）。
    @Test func reversalPassesZeroContinuously() {
        let collapsingBefore = LaunchpadWindowController.pinchVisualProgress(startVisible: true, signedProgress: -0.001)
        let collapsingAfter = LaunchpadWindowController.pinchVisualProgress(startVisible: true, signedProgress: 0.001)
        #expect(abs(collapsingBefore - collapsingAfter) < 0.01)
        let expandingBefore = LaunchpadWindowController.pinchVisualProgress(startVisible: false, signedProgress: -0.001)
        let expandingAfter = LaunchpadWindowController.pinchVisualProgress(startVisible: false, signedProgress: 0.001)
        #expect(abs(expandingBefore - expandingAfter) < 0.01)
    }

    /// 越界值钳制到 0...1。
    @Test func clampsOutOfRange() {
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: false, signedProgress: 1.5) == 1)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: false, signedProgress: -1.5) == 0)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: true, signedProgress: -1.5) == 0)
        #expect(LaunchpadWindowController.pinchVisualProgress(startVisible: true, signedProgress: 1.5) == 1)
    }
}

@MainActor
struct PinchCloseSessionTests {

    private func makeController() throws -> (controller: LaunchpadWindowController, model: LaunchpadModel, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPinch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LayoutStore(directory: dir)
        // 回退路径会经 targetScreen() 安排壁纸刷新：测试进程未创建 NSApp，
        // 「激活屏」档位会隐式解包 NSApp.keyWindow 而崩溃，固定为「主屏」档；
        // 同时关闭模糊壁纸，回退后走轻量分支，不做屏幕捕获。
        store.updateSettings {
            $0.screenPosition = .main
            $0.blurWallpaper = false
        }
        let model = LaunchpadModel(store: store)
        return (LaunchpadWindowController(model: model), model, dir)
    }

    /// 识别瞬间面板保持展开态（1 - p），不得跳到 0；跟手阶段随手势收缩。
    @Test func closeRecognitionKeepsPanelExpandedInsteadOfFlashing() throws {
        let (controller, model, dir) = try makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.show()
        controller.handlePinchGesture(PinchGestureEvent(phase: .began, signedProgress: 0))
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.05))
        // 首帧视觉 = 1 - 0.05（旧实现为 0.05，即闪烁到全透明的根因）
        #expect(abs((model.pinchTransitionProgress ?? 0) - 0.95) < 0.0001)
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.4))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 0.6) < 0.0001)
        // 松手过半：提交收起，视觉交还 isVisible 驱动（false → 0）
        controller.handlePinchGesture(PinchGestureEvent(phase: .ended, signedProgress: -0.8))
        #expect(!model.isVisible)
        #expect(model.pinchTransitionProgress == nil)
    }

    /// 松手未过半：回退到展开态，不落位收起。
    @Test func closeBelowHalfRollsBackToExpanded() throws {
        let (controller, model, dir) = try makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.show()
        controller.handlePinchGesture(PinchGestureEvent(phase: .began, signedProgress: 0))
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.3))
        controller.handlePinchGesture(PinchGestureEvent(phase: .ended, signedProgress: -0.3))
        #expect(model.isVisible)
        #expect(model.pinchTransitionProgress == nil)
    }

    /// 上一手势缺终帧时，新手势 began 先无动画回退；新会话不继承半途的视觉状态。
    @Test func staleCloseGestureRollsBackOnNextBegan() throws {
        let (controller, model, dir) = try makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.show()
        controller.handlePinchGesture(PinchGestureEvent(phase: .began, signedProgress: 0))
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.4))
        controller.handlePinchGesture(PinchGestureEvent(phase: .began, signedProgress: 0))
        #expect(model.isVisible)
        #expect(model.pinchTransitionProgress == nil)
    }

    /// 设备停止收尾序列（积压 changed 在前、cancelled 收尾）送入控制器后，
    /// 面板回到起点、跟手态完全退出——不得残留 isPinchInteracting。
    /// 反例（旧顺序 cancelled → changed）会让孤立的 changed 开启新会话卡住。
    @Test func deviceShutdownSequenceLeavesNoStuckSession() throws {
        let (controller, model, dir) = try makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.show()
        controller.handlePinchGesture(PinchGestureEvent(phase: .began, signedProgress: 0))
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.2))
        // stopDevice 的收尾：邮箱积压的 changed，然后 abort 的 cancelled
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.3))
        controller.handlePinchGesture(PinchGestureEvent(phase: .cancelled, signedProgress: -0.3))
        #expect(model.isVisible)
        #expect(model.pinchTransitionProgress == nil)
        #expect(!model.isPinchInteracting, "收尾后不得残留跟手态")

        // 对照：旧顺序（cancelled 先到、晚到的 changed 后到）会重开会话并卡住
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.3))
        #expect(model.isPinchInteracting, "孤立 changed 确实会开启会话——收尾顺序必须保证它不晚于 cancelled")
    }

    // MARK: 不抬手反向（捏合中途再张开 / 张开中途再捏合）

    /// 不抬手「捏合 → 张开」：过零后视觉钳在展开态（不弹回起点再塌缩），
    /// 终帧为张开且过半时保持展开。回归：冻结方向的旧映射在这里先闪烁、
    /// 并把终帧 +0.6 误判成「收起提交」把面板关掉。
    @Test func pinchThenSpreadWithoutLiftStaysOpen() throws {
        let (controller, model, dir) = try makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.show()
        controller.handlePinchGesture(PinchGestureEvent(phase: .began, signedProgress: 0))
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.6))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 0.4) < 0.0001)
        // 反向张开：过零附近视觉 ≈1 且继续张开钳在 1（旧实现塌回 0.8 → 闪烁）
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: 0.2))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 1) < 0.0001)
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: 0.6))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 1) < 0.0001)
        controller.handlePinchGesture(PinchGestureEvent(phase: .ended, signedProgress: 0.6))
        #expect(model.isVisible)
        #expect(model.pinchTransitionProgress == nil)
    }

    /// 不抬手「捏合 → 张开 → 再捏合并过半」：按终帧方向收起。
    @Test func spreadBackThenPinchDeepCloses() throws {
        let (controller, model, dir) = try makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.show()
        controller.handlePinchGesture(PinchGestureEvent(phase: .began, signedProgress: 0))
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.3))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 0.7) < 0.0001)
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: 0.5))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 1) < 0.0001)
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.9))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 0.1) < 0.0001)
        controller.handlePinchGesture(PinchGestureEvent(phase: .ended, signedProgress: -0.9))
        #expect(!model.isVisible)
        #expect(model.pinchTransitionProgress == nil)
    }

    /// 展开会话中途捏回但未过半：手指回撤时面板跟着收缩（有符号进度是相对
    /// 手势起点的绝对值，捏过头钳在收起态 0），终帧低于一半回退到会话起点（收起）。
    @Test func openSessionPinchBackBelowHalfRevertsToHidden() throws {
        let (controller, model, dir) = try makeController()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!model.isVisible)
        controller.handlePinchGesture(PinchGestureEvent(phase: .began, signedProgress: 0))
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: 0.7))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 0.7) < 0.0001)
        // 手指回撤（仍为正）：面板从 0.7 收缩到 0.2，连续无跳变
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: 0.2))
        #expect(abs((model.pinchTransitionProgress ?? 0) - 0.2) < 0.0001)
        // 捏过头（过零为负）：钳在收起态 0
        controller.handlePinchGesture(PinchGestureEvent(phase: .changed, signedProgress: -0.4))
        #expect(model.pinchTransitionProgress == 0)
        controller.handlePinchGesture(PinchGestureEvent(phase: .ended, signedProgress: -0.4))
        #expect(!model.isVisible)
        #expect(model.pinchTransitionProgress == nil)
    }
}
