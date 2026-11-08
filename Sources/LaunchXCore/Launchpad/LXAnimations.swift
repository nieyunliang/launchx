import SwiftUI

/// 翻页统一动画：整页条带滑动的落位质感。
///
/// 曲线用快启动缓出（easeOutCubic：cubic-bezier(0.215, 0.61, 0.355, 1)）：
/// 指尖/按键一触发位移立刻跟上（前半段时间走完约 84% 行程），收尾平滑减速，
/// 纵坐标不过 1 → 无过冲。时长取「干脆」档：慢速跟手后落位不拖沓，
/// 快速连滑依赖落位期接管（见 LaunchpadModel.takeOverPageSettle）而非缩短死等。
/// 落位收尾定时器（LaunchpadModel）引用同一常量与同一组控制点，避免两处漂移。
extension Animation {
    /// 条带滑动时长（秒）：横滑落位 / 键盘与页码点导航共用。
    static let pageSlideSeconds: TimeInterval = 0.3
    /// 橡皮筋回弹时长（秒）：回程 ≤ 1/4 页宽，略短收住。
    static let pageBounceBackSeconds: TimeInterval = 0.25

    /// 翻页条带滑动 / 键盘与页码点导航：快启动缓出，无过冲。
    static let pageSlide = Animation.timingCurve(
        PageSlideCurve.x1, PageSlideCurve.y1, PageSlideCurve.x2, PageSlideCurve.y2,
        duration: pageSlideSeconds
    )

    /// 橡皮筋回弹（未过阈值松手）：同曲线收短时长，避免拖泥带水。
    static let pageBounceBack = Animation.timingCurve(
        PageSlideCurve.x1, PageSlideCurve.y1, PageSlideCurve.x2, PageSlideCurve.y2,
        duration: pageBounceBackSeconds
    )
}

/// 翻页曲线的单一事实来源：SwiftUI `timingCurve` 与 CSS cubic-bezier 同数学。
///
/// `progress(atX:)` 供横滑落位动画做解析取值——落位期间新手势接管时，
/// 模型里只有动画目标值，表现值（屏幕上条带的实际位置）按曲线反解出来，
/// 接管起点与在屏画面逐帧一致，无跳变。
enum PageSlideCurve {
    static let x1: CGFloat = 0.215
    static let y1: CGFloat = 0.61
    static let x2: CGFloat = 0.355
    static let y2: CGFloat = 1.0

    /// 三次贝塞尔 y(t)（控制点纵坐标插值）。
    private static func bezierY(_ s: Double) -> Double {
        let om = 1 - s
        return 3 * om * om * s * Double(y1) + 3 * om * s * s * Double(y2) + s * s * s
    }

    /// 三次贝塞尔 x(t)。
    private static func bezierX(_ s: Double) -> Double {
        let om = 1 - s
        return 3 * om * om * s * Double(x1) + 3 * om * s * s * Double(x2) + s * s * s
    }

    /// 曲线在横坐标 x（时间进度 0...1）处的纵坐标（位移进度 0...1）。
    /// 以 Newton 迭代反解参数 t（cubic-bezier 标准解法），端点直接返回。
    static func progress(atX x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var s = x  // 初值：x 与 t 同向单调，x 本身已是不错的起点
        for _ in 0..<8 {
            let diff = bezierX(s) - x
            if abs(diff) < 1e-7 { break }
            // dx/ds = 3(1-s)²x1 + 6(1-s)s(x2-x1) + 3s²(1-x2)
            let om = 1 - s
            let dx = 3 * om * om * Double(x1)
                + 6 * om * s * (Double(x2) - Double(x1))
                + 3 * s * s * (1 - Double(x2))
            guard dx > 1e-9 else { break }  // x 单调递增，导数恒正；防御除零
            s -= diff / dx
            s = min(max(s, 0), 1)
        }
        return bezierY(s)
    }
}

// MARK: - 减弱动态效果（Reduce Motion）

/// 「减弱动态效果」适配（P3-3）。
///
/// 所有数值都收敛到 `Profile` 这一纯函数出口，便于单测；
/// 调用方传入系统当前状态（视图用 `\.accessibilityReduceMotion` 环境值，
/// 控制器用 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`）。
///
/// 开启时：去掉内容的 1.15 倍缩放、弹簧与长时长，只保留快速淡入淡出；
/// 功能不受影响——捏合跟手仍跟手，只是内容不再缩放。
enum MotionPreference {
    struct Profile: Equatable {
        /// 内容起始缩放（1 = 不缩放）。
        let contentScaleStart: Double
        /// 面板展开/收起的时长（秒）。
        let transitionDuration: Double
        /// 展开动画是否用弹簧（false = easeOut，无回弹）。
        let usesSpringTransition: Bool
        /// 翻页动画时长（秒）。
        let pageSlideDuration: Double
    }

    /// 归零档：关掉缩放、回弹与长时长，只留 ~0.12s 淡入淡出。
    static let reduced = Profile(
        contentScaleStart: 1,
        transitionDuration: 0.12,
        usesSpringTransition: false,
        pageSlideDuration: 0.12
    )

    /// 常态档：与改动前完全一致（1.15 → 1.0 弹簧收缩 + 0.3s 翻页）。
    static let standard = Profile(
        contentScaleStart: 1.15,
        transitionDuration: Animation.pageSlideSeconds,
        usesSpringTransition: true,
        pageSlideDuration: Animation.pageSlideSeconds
    )

    static func profile(reduceMotion: Bool) -> Profile {
        reduceMotion ? reduced : standard
    }

    /// 内容缩放：progress 0（收起）→ contentScaleStart，1（展开）→ 1.0。
    static func contentScale(progress: Double, reduceMotion: Bool) -> Double {
        let profile = profile(reduceMotion: reduceMotion)
        let clamped = min(max(progress, 0), 1)
        return profile.contentScaleStart + (1 - profile.contentScaleStart) * clamped
    }

    /// 面板展开/收起动画。
    static func panelTransition(reduceMotion: Bool) -> Animation {
        let profile = profile(reduceMotion: reduceMotion)
        if profile.usesSpringTransition {
            return .spring(duration: profile.transitionDuration, bounce: 0.12)
        }
        return .easeOut(duration: profile.transitionDuration)
    }

    /// 翻页动画：与常态同曲线，减弱动态效果时只缩短时长。
    static func pageSlide(reduceMotion: Bool) -> Animation {
        let profile = profile(reduceMotion: reduceMotion)
        return .timingCurve(
            PageSlideCurve.x1, PageSlideCurve.y1, PageSlideCurve.x2, PageSlideCurve.y2,
            duration: profile.pageSlideDuration
        )
    }
}
