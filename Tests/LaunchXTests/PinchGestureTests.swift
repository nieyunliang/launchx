import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 捏合手势档位（含四指精确档）

struct PinchGestureTests {

    @Test func fourFingerOptionExistsWithLabel() {
        #expect(PinchGesture.allCases.contains(.fourFinger))
        #expect(PinchGesture.fourFinger.label == "四指捏合")
    }

    @Test func allCasesOrderMatchesSettingsPicker() {
        #expect(PinchGesture.allCases == [.off, .threeFinger, .fourFinger, .fourFiveFinger, .fiveFinger])
    }

    /// 手指越多累计幅度越大，阈值应随档位递增；关闭档不应触发。
    @Test func triggerMagnitudeIncreasesWithFingerCount() {
        let magnitudes = PinchGesture.allCases.map { TrackpadGestureMonitor.triggerMagnitude(for: $0) }
        #expect(magnitudes[0] == .infinity)
        #expect(magnitudes[1] < magnitudes[2])  // 三指 < 四指
        #expect(magnitudes[2] < magnitudes[3])  // 四指 < 四或五指
        #expect(magnitudes[3] < magnitudes[4])  // 四或五指 < 五指
        #expect(magnitudes.allSatisfy { $0 > 0 })
    }

    @Test func decodingLegacySettingsKeepsPinchValues() throws {
        // 旧版存档（不含四指档字段结构变化）仍可解码
        let legacy = #"{"pinchGesture":"fourFiveFinger"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(decoded.pinchGesture == .fourFiveFinger)

        // 新档位原样往返
        let fourFinger = #"{"pinchGesture":"fourFinger"}"#
        let decodedFour = try JSONDecoder().decode(AppSettings.self, from: Data(fourFinger.utf8))
        #expect(decodedFour.pinchGesture == .fourFinger)

        // 默认值仍为关闭
        #expect(AppSettings().pinchGesture == .off)
        let encoded = try JSONEncoder().encode(AppSettings())
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: encoded)
        #expect(roundTripped.pinchGesture == .off)
    }
}

// MARK: - 逐帧跟手与吞帧拦截策略

struct GestureInterceptionTests {

    private let threshold = TrackpadGestureMonitor.triggerMagnitude(for: .fourFinger)
    private var recognition: CGFloat { threshold * TrackpadGestureMonitor.recognitionRatio }

    /// 识别前的帧放行且不投递：普通小幅缩放不受影响。
    @Test func passesFramesBelowRecognitionThreshold() {
        let decision = TrackpadGestureMonitor.consumeDecision(
            phase: .changed, magnitude: recognition / 2,
            recognitionThreshold: recognition, intercepting: false)
        #expect(!decision.consume)
        #expect(!decision.intercepting)
        #expect(!decision.emit)
    }

    /// 到达识别点即开始逐帧跟手，而不是执行一次 toggle。
    @Test func startsTrackingAtRecognitionThreshold() {
        let decision = TrackpadGestureMonitor.consumeDecision(
            phase: .changed, magnitude: recognition,
            recognitionThreshold: recognition, intercepting: false)
        #expect(decision.consume)
        #expect(decision.intercepting)
        #expect(decision.emit)
    }

    /// ended 必须投递给窗口层落位，同时结束拦截；下一手势重新判定。
    @Test func deliversEndedAndResetsInterception() {
        let ended = TrackpadGestureMonitor.consumeDecision(
            phase: .ended, magnitude: threshold,
            recognitionThreshold: recognition, intercepting: true)
        #expect(ended.consume)
        #expect(!ended.intercepting)
        #expect(ended.emit)

        let began = TrackpadGestureMonitor.consumeDecision(
            phase: .began, magnitude: 0,
            recognitionThreshold: recognition, intercepting: false)
        #expect(!began.consume && !began.intercepting && !began.emit)
    }

    /// 系统取消同样投递，以便窗口回退；取消帧仍被吞掉。
    @Test func deliversCancelledGestureForRollback() {
        let decision = TrackpadGestureMonitor.consumeDecision(
            phase: .cancelled, magnitude: threshold,
            recognitionThreshold: recognition, intercepting: true)
        #expect(decision.consume)
        #expect(!decision.intercepting)
        #expect(decision.emit)
    }

    /// 识别点为 0、完整行程为 1，中间线性跟手，越界值钳制。
    @Test func mapsGestureMagnitudeToNormalizedProgress() {
        #expect(TrackpadGestureMonitor.normalizedProgress(
            magnitude: recognition, threshold: threshold) == 0)
        #expect(TrackpadGestureMonitor.normalizedProgress(
            magnitude: (recognition + threshold) / 2, threshold: threshold) == 0.5)
        #expect(TrackpadGestureMonitor.normalizedProgress(
            magnitude: threshold, threshold: threshold) == 1)
        #expect(TrackpadGestureMonitor.normalizedProgress(
            magnitude: threshold * 2, threshold: threshold) == 1)
        #expect(TrackpadGestureMonitor.normalizedProgress(
            magnitude: 0, threshold: threshold) == 0)
    }

    /// 松手过半完成，未过半或系统取消则回退；方向不影响提交判断。
    @Test func settlesFromCurrentProgress() {
        #expect(LaunchpadWindowController.shouldCommitPinch(progress: 0.5, cancelled: false))
        #expect(LaunchpadWindowController.shouldCommitPinch(progress: -0.5, cancelled: false))
        #expect(!LaunchpadWindowController.shouldCommitPinch(progress: 0.49, cancelled: false))
        #expect(!LaunchpadWindowController.shouldCommitPinch(progress: 1, cancelled: true))
    }
}
