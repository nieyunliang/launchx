import AppKit
import SwiftUI

/// 首次引导窗口：Welcome → 教学 → 一切就绪。
///
/// 视觉：全出血柔光渐变 + 液态玻璃（与主界面 Liquid Glass 同语言），
/// 亮暗双套配色；标题栏透明，内容延伸到红绿灯下方。
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    public var onFinished: (() -> Void)?

    public override init() {
        super.init()
    }

    public func show() {
        guard let window else {
            makeWindow()
            return
        }
        // 复用时重建内容视图，让步骤从头开始。
        window.contentView = NSHostingView(rootView: makeContent())
        WindowFade.fadeIn(window)
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 LaunchX"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: makeContent())
        window.center()
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        WindowFade.fadeIn(window)
    }

    private func makeContent() -> OnboardingContentView {
        OnboardingContentView(
            onFinished: { [weak self] in
                self?.closeAndFinish()
            },
            onRequestClose: { [weak self] in
                self?.closeAndFinish()
            }
        )
    }

    /// 关闭（红叉 / Esc）与「开始使用」走同一条收尾路径：
    /// 都视为引导已完成，避免下次启动反复弹出。
    private func closeAndFinish() {
        guard let window else { return }
        WindowFade.fadeOut(window)
        onFinished?()
    }

    /// 关闭按钮 → 淡出后仅移出屏幕（窗口对象保留供复用）；
    /// 同时标记引导已完成（否则每次启动都会再次弹出）。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeAndFinish()
        return false
    }
}

// MARK: - 引导内容

/// 引导内容：3 步，ZStack + 方向性滑动过渡（替代 TabView 默认翻页）。
public struct OnboardingContentView: View {
    let onFinished: () -> Void
    var onRequestClose: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Int
    @State private var backward = false
    @State private var confettiVisible = false
    @State private var finishing = false

    private let stepCount = 3
    private var palette: OnboardingPalette { .palette(for: colorScheme) }

    /// initialStep 供视觉验证 / 测试直接落到某一幕。
    public init(
        onFinished: @escaping () -> Void,
        onRequestClose: @escaping () -> Void = {},
        initialStep: Int = 0
    ) {
        self.onFinished = onFinished
        self.onRequestClose = onRequestClose
        _step = State(initialValue: initialStep)
    }

    public var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                stepSwitcher
                controlBar
            }
        }
        .overlay {
            if confettiVisible {
                ConfettiView()
                    .allowsHitTesting(false)
            }
        }
        .onExitCommand { onRequestClose() }
        .onChange(of: step) { _, newValue in
            if newValue == 2, !reduceMotion {
                confettiVisible = true
            }
        }
        .frame(width: 560, height: 680)
    }

    // MARK: 背景

    /// 柔光渐变（延续 GuideBg 暖白 → 冷雾蓝的色相）+ 两团装饰光晕。
    private var background: some View {
        ZStack {
            LinearGradient(
                colors: palette.background,
                startPoint: .top,
                endPoint: .bottom
            )
            GeometryReader { proxy in
                Circle()
                    .fill(palette.orbA)
                    .frame(width: 320, height: 320)
                    .blur(radius: 72)
                    .offset(x: proxy.size.width - 170, y: -120)
                Circle()
                    .fill(palette.orbB)
                    .frame(width: 280, height: 280)
                    .blur(radius: 72)
                    .offset(x: -130, y: proxy.size.height - 230)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 步骤切换

    private var stepSwitcher: some View {
        ZStack {
            switch step {
            case 0: WelcomeStep(palette: palette).transition(stepTransition)
            case 1: TeachingStep(palette: palette).transition(stepTransition)
            default: AllSetStep(palette: palette).transition(stepTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: backward ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: backward ? .trailing : .leading).combined(with: .opacity)
        )
    }

    private var stepAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.15)
            : .spring(response: 0.45, dampingFraction: 0.85)
    }

    // MARK: 底部控制条

    private var controlBar: some View {
        ZStack {
            HStack {
                Button {
                    guard step > 0 else { return }
                    backward = true
                    withAnimation(stepAnimation) { step -= 1 }
                } label: {
                    Label("上一步", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(step == 0)
                .opacity(step == 0 ? 0 : 1)
                .accessibilityHidden(step == 0)

                Spacer()

                Button {
                    if step == stepCount - 1 {
                        finish()
                    } else {
                        backward = false
                        withAnimation(stepAnimation) { step += 1 }
                    }
                } label: {
                    if step == stepCount - 1 {
                        Label("开始使用", systemImage: "rocket.fill")
                    } else {
                        Text("继续")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
                .frame(minWidth: 148)
            }
            .padding(.horizontal, 26)
            .padding(.top, 8)
            .padding(.bottom, 26)

            stepDots
        }
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index == step ? LXColors.accent : palette.dotInactive)
                    .frame(width: index == step ? 22 : 7, height: 7)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step + 1) 步，共 \(stepCount) 步")
    }

    // MARK: 收尾

    private func finish() {
        guard !finishing else { return }
        finishing = true
        if reduceMotion {
            onFinished()
        } else {
            // 留一拍给彩带落下，再淡出窗口。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                onFinished()
            }
        }
    }
}

// MARK: - 配色 Token

/// 引导页亮 / 暗双套配色（背景延续 GuideBg 品牌色相；正文对比度按 AA 校过）。
struct OnboardingPalette {
    let background: [Color]
    let orbA: Color
    let orbB: Color
    let title: Color
    let body: Color
    let secondary: Color
    let dotInactive: Color

    static func palette(for scheme: ColorScheme) -> OnboardingPalette {
        scheme == .dark ? dark : light
    }

    static let light = OnboardingPalette(
        background: [
            Color(red: 0xF8 / 255, green: 0xF7 / 255, blue: 0xF4 / 255),
            Color(red: 0xE4 / 255, green: 0xE9 / 255, blue: 0xF2 / 255),
            Color(red: 0xA9 / 255, green: 0xB9 / 255, blue: 0xD6 / 255),
        ],
        orbA: LXColors.accent.opacity(0.22),
        orbB: Color(red: 0x9B / 255, green: 0x8C / 255, blue: 0xFF / 255).opacity(0.22),
        title: Color(red: 0.11, green: 0.11, blue: 0.15),
        body: Color(red: 0.15, green: 0.15, blue: 0.20),
        secondary: Color.black.opacity(0.66),
        dotInactive: Color.black.opacity(0.22)
    )

    static let dark = OnboardingPalette(
        background: [
            Color(red: 0x2E / 255, green: 0x35 / 255, blue: 0x48 / 255),
            Color(red: 0x23 / 255, green: 0x29 / 255, blue: 0x39 / 255),
            Color(red: 0x14 / 255, green: 0x18 / 255, blue: 0x24 / 255),
        ],
        orbA: LXColors.accent.opacity(0.28),
        orbB: Color(red: 0x7C / 255, green: 0x6C / 255, blue: 0xFF / 255).opacity(0.20),
        title: .white,
        body: Color.white.opacity(0.92),
        secondary: Color.white.opacity(0.65),
        dotInactive: Color.white.opacity(0.28)
    )
}

// MARK: - 步骤 1：Welcome

/// 欢迎页：迷你 Launchpad 玻璃模型 + 品牌标语 + 特性胶囊。
private struct WelcomeStep: View {
    let palette: OnboardingPalette

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 12)
            LaunchpadMockView(palette: palette)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                EyebrowLabel(text: "欢迎", palette: palette)
                Text("LaunchX")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.title)
                Text("macOS 启动台的完整复刻与增强替代品")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                GlassChip(palette: palette, text: "图标网格")
                GlassChip(palette: palette, text: "文件夹")
                GlassChip(palette: palette, text: "拖拽整理")
                GlassChip(palette: palette, text: "应用卸载器")
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 32)
    }
}

/// 迷你 Launchpad 模型：搜索胶囊 + 应用磁贴网格 + 页码点，磁贴逐个弹入。
private struct LaunchpadMockView: View {
    let palette: OnboardingPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilesIn = false

    private static let tileSymbols = [
        "globe", "message", "photo.on.rectangle", "music.note", "calendar", "map",
        "mail", "terminal", "camera", "clock", "notes", "paintbrush",
        "gamecontroller", "chart.bar", "cloud", "pencil", "wallet.pass", "fitness",
    ]

    private static let tileGradients: [[Color]] = [
        [.blue, .cyan], [.orange, .red], [.purple, .pink],
        [.green, .mint], [.indigo, .blue], [.pink, .orange],
    ]

    var body: some View {
        VStack(spacing: 12) {
            mockSearchBar
            mockTileGrid
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == 0 ? palette.title : palette.title.opacity(0.25))
                        .frame(width: 4, height: 4)
                }
            }
        }
        .padding(16)
        .frame(width: 272)
        .liquidGlassPanel(cornerRadius: 24)
        .onAppear {
            guard !reduceMotion else {
                tilesIn = true
                return
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                tilesIn = true
            }
        }
    }

    private var mockSearchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
            RoundedRectangle(cornerRadius: 2)
                .fill(palette.title.opacity(0.25))
                .frame(height: 3)
            Image(systemName: "ellipsis")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(palette.title.opacity(0.08)))
    }

    private var mockTileGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(30), spacing: 12), count: 6),
            spacing: 12
        ) {
            ForEach(Array(Self.tileSymbols.enumerated()), id: \.offset) { index, symbol in
                RoundedRectangle(cornerRadius: 30 * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: Self.tileGradients[index % Self.tileGradients.count],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                    .scaleEffect(tilesIn ? 1 : 0.5)
                    .opacity(tilesIn ? 1 : 0)
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.4, dampingFraction: 0.75)
                                .delay(Double(index) * 0.03),
                        value: tilesIn
                    )
            }
        }
    }
}

// MARK: - 步骤 2：教学

/// 教学页：三张玻璃卡片，逐张浮现。
private struct TeachingStep: View {
    let palette: OnboardingPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardsIn = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 6) {
                EyebrowLabel(text: "快速上手", palette: palette)
                Text("三件事，立刻上手")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.title)
            }
            VStack(spacing: 14) {
                TeachingCard(
                    palette: palette, visual: .commandKey, index: 0, entered: cardsIn,
                    title: "按住 ⌘ 点选 / 框选多个应用",
                    subtitle: "多选后可整体移动、排序或合并进文件夹"
                )
                TeachingCard(
                    palette: palette, visual: .menuButton, index: 1, entered: cardsIn,
                    title: "搜索栏右侧的菜单按钮",
                    subtitle: "整理布局 · 新建文件夹 · 解散全部文件夹"
                )
                TeachingCard(
                    palette: palette, visual: .dragMerge, index: 2, entered: cardsIn,
                    title: "把一个应用拖到另一个应用上",
                    subtitle: "自动创建文件夹；拖出即解散"
                )
            }
            .padding(.top, 30)
            Spacer()
        }
        .padding(.horizontal, 36)
        .onAppear {
            guard !reduceMotion else {
                cardsIn = true
                return
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                cardsIn = true
            }
        }
    }
}

/// 教学卡片：左侧强调色磁贴示意图 + 右侧文案，液态玻璃底。
private struct TeachingCard: View {
    enum Visual { case commandKey, menuButton, dragMerge }

    let palette: OnboardingPalette
    let visual: Visual
    let index: Int
    let entered: Bool
    let title: String
    let subtitle: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            visualView
                .frame(width: 46, height: 46)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.title)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .liquidGlassPanel(cornerRadius: 16)
        .opacity(entered ? 1 : 0)
        .offset(y: entered ? 0 : 14)
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.09),
            value: entered
        )
    }

    private var visualView: some View {
        let gradient = LinearGradient(
            colors: [LXColors.accent, .cyan],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return ZStack {
            switch visual {
            case .commandKey:
                Image(systemName: "command")
                    .font(.system(size: 20, weight: .semibold))
            case .menuButton:
                Capsule()
                    .fill(.white.opacity(0.32))
                    .frame(width: 34, height: 18)
                HStack(spacing: 2) {
                    Image(systemName: "magnifyingglass")
                    Spacer()
                    Image(systemName: "ellipsis")
                }
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(width: 34)
            case .dragMerge:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .offset(x: -6, y: -6)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 5, y: 5)
            }
        }
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 46 * 0.24, style: .continuous)
                .fill(gradient)
        )
    }
}

// MARK: - 步骤 3：一切就绪

/// 完成页：对勾弹出 + 唤起方式胶囊 + 彩带（由容器触发）。
private struct AllSetStep: View {
    let palette: OnboardingPalette

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkIn = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.green.opacity(colorScheme == .dark ? 0.18 : 0.14))
                    .frame(width: 120, height: 120)
                Image(systemName: "checkmark")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.green)
            }
            .scaleEffect(checkIn ? 1 : 0.4)
            .opacity(checkIn ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    checkIn = true
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                EyebrowLabel(text: "完成", palette: palette)
                Text("一切就绪！")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.title)
                Text("用任意一种方式，随时唤起 LaunchX")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary)
            }
            .padding(.top, 24)
            HStack(spacing: 8) {
                GlassChip(palette: palette, icon: "keyboard", text: "自定义快捷键")
                GlassChip(palette: palette, icon: "hand.draw", text: "捏合手势")
            }
            .padding(.top, 20)
            Spacer()
            Text("唤起方式可在 设置 → 通用 中随时调整")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 36)
        .onAppear {
            if reduceMotion {
                checkIn = true
            }
        }
    }
}

// MARK: - 通用小组件

/// 步骤眉标（小号字距放大）。
private struct EyebrowLabel: View {
    let text: String
    let palette: OnboardingPalette

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .tracking(3)
            .foregroundStyle(palette.secondary)
    }
}

/// 玻璃胶囊标签（特性 / 唤起方式）。
private struct GlassChip: View {
    let palette: OnboardingPalette
    var icon: String?
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(palette.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .liquidGlassCapsule()
    }
}

/// 彩带粒子动画（Confetti）。
struct ConfettiView: View {
    @State private var animate = false

    private static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]

    private struct Piece: Identifiable {
        let id: Int
        let x: CGFloat      // 0-1 横向位置
        let delay: Double
        let rotation: Double
        let color: Color
        let size: CGFloat
    }

    private let pieces: [Piece] = (0..<72).map { index in
        Piece(
            id: index,
            x: .random(in: 0.05...0.95),
            delay: .random(in: 0...0.7),
            rotation: .random(in: 0...360),
            color: Self.colors[index % Self.colors.count],
            size: .random(in: 5...10)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(pieces) { piece in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(piece.color)
                    .frame(width: piece.size, height: piece.size * 1.6)
                    .rotationEffect(.degrees(animate ? piece.rotation + 360 : piece.rotation))
                    .position(
                        x: proxy.size.width * piece.x,
                        y: animate ? proxy.size.height + 40 : -40
                    )
                    .animation(
                        .easeIn(duration: 1.5).delay(piece.delay),
                        value: animate
                    )
            }
        }
        .onAppear {
            animate = true
        }
    }
}
