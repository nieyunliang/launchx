import AppKit
import Carbon.HIToolbox

/// 当前键盘输入源能力查询。
///
/// 「输入即搜索」在面板层直接消费首个可打印字符：英文键盘没问题，但中文/日文等
/// 输入法（IME）的首键会被当成原始字母写进查询，之后 IME 从第二个键才开始组字，
/// 查询永远匹配不到目标应用。因此需要知道当前输入源能否直接产生 ASCII。
public enum InputSource {
    /// 当前键盘输入源是否可直接输入 ASCII（英文键盘为 true，中文/日文等 IME 为 false）。
    nonisolated public static var isASCIICapable: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return true }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return true
        }
        let flag = Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
        return CFBooleanGetValue(flag)
    }
}

/// 虚拟键码 / 修饰键工具（纯函数，无状态，重点可测）。
///
/// Carbon 修饰键常量（HIToolbox Events.h 中的经典位掩码，此处自定义 UInt32 常量，
/// 避免直接引入 Carbon 的 Int 常量参与位运算）。
public enum KeyCodes {
    /// ⌘ Command（cmdKey = 0x0100）。
    public static let cmdKey: UInt32 = 0x0100
    /// ⇧ Shift（shiftKey = 0x0200）。
    public static let shiftKey: UInt32 = 0x0200
    /// ⇪ Caps Lock（alphaLock = 0x0400）。
    public static let alphaLock: UInt32 = 0x0400
    /// ⌥ Option / Alt（optionKey = 0x0800）。
    public static let optionKey: UInt32 = 0x0800
    /// ⌃ Control（controlKey = 0x1000）。
    public static let controlKey: UInt32 = 0x1000

    /// 虚拟键码 → 显示名 对照表（ANSI 布局）。
    /// 字母/数字/标点 0–53，功能键 96–113，导航键 114–126。
    private static let keyCodeNames: [UInt32: String] = [
        // 字母（kVK_ANSI_*，A=0 起）
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
        6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        45: "N", 46: "M",
        // 数字（kVK_ANSI_0 = 29，1=18、2=19、3=20、4=21、5=23、6=22、7=26、8=28、9=25）
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        25: "9", 26: "7", 28: "8", 29: "0",
        // 标点（39:"'" 与 41:";" 已并入字母区，避免字典键重复）
        24: "=", 27: "-", 30: "]", 33: "[", 42: "\\",
        43: ",", 44: "/", 47: ".", 50: "`",
        // 控制键
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        // 小键盘（可选，供录制器识别）
        67: "Keypad *", 69: "Keypad +", 71: "Keypad Clear", 75: "Keypad /",
        76: "Keypad Enter", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
        86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
        90: "Keypad 8", 91: "Keypad 9",
        // 功能键 F1–F12（122,120,99,118,96,97,98,100,101,109,103,111）+ F13–F15
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        // 导航与方向键（←=123、↑=126、→=124、↓=125）
        114: "Help", 115: "Home", 116: "PageUp", 117: "⌦",
        118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// 虚拟键码 → 显示名："Space"、"F6"、"A"、"0"、"←" 等；未知返回 nil。
    public static func string(for keyCode: UInt32) -> String? {
        keyCodeNames[keyCode]
    }

    /// 完整显示串，修饰键顺序固定为 ⌘⌃⌥⇧，如 "⌥Space"、"⌘⇧Space"。
    /// 未知键码回退为 "Key<码>"，保证结果非空（用于设置页兜底展示）。
    public static func displayString(for spec: HotKeySpec) -> String {
        var result = ""
        if spec.modifiers & cmdKey != 0 { result += "⌘" }
        if spec.modifiers & controlKey != 0 { result += "⌃" }
        if spec.modifiers & optionKey != 0 { result += "⌥" }
        if spec.modifiers & shiftKey != 0 { result += "⇧" }
        result += string(for: spec.keyCode) ?? "Key\(spec.keyCode)"
        return result
    }

    /// NSEvent.ModifierFlags（仅 deviceIndependentFlagsMask 相关位）→ Carbon 掩码。
    public static func carbonFlags(from cocoa: NSEvent.ModifierFlags) -> UInt32 {
        // 只关心设备无关位，剥掉左侧设备相关位（如设备位 0xFF00 段）
        let flags = cocoa.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        // CapsLock 的 alphaLock 是键盘状态位、不是热键修饰键：映射进去会让掩码带着锁定位，
        // 导致校验的精确相等判断全部失效，且注册出的热键在 Caps Lock 关闭时永不触发。
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        return carbon
    }

    /// Carbon 掩码 → NSEvent.ModifierFlags（逆映射，仅五位已知修饰键）。
    public static func cocoaFlags(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & cmdKey != 0 { flags.insert(.command) }
        if carbon & shiftKey != 0 { flags.insert(.shift) }
        if carbon & alphaLock != 0 { flags.insert(.capsLock) }
        if carbon & optionKey != 0 { flags.insert(.option) }
        if carbon & controlKey != 0 { flags.insert(.control) }
        return flags
    }

    /// 预设方案（名字 → spec），名字与 displayString 输出一致：
    /// "⌥Space"（默认，49 + optionKey 0x0800）、"⌘⇧Space"、"⌥⇧Space"、"F6"。
    public static let presets: [String: HotKeySpec] = [
        "⌥Space": HotKeySpec(keyCode: 49, modifiers: optionKey),
        "⌘⇧Space": HotKeySpec(keyCode: 49, modifiers: cmdKey | shiftKey),
        "⌥⇧Space": HotKeySpec(keyCode: 49, modifiers: optionKey | shiftKey),
        "F6": HotKeySpec(keyCode: 97, modifiers: 0),
    ]

    /// F1–F15 的虚拟键码（ANSI）。功能键允许任意修饰组合，包括无修饰。
    static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
    ]

    /// Esc 键虚拟键码（录制器取消用）。
    public static let kVK_Escape: UInt16 = 53

    // MARK: - 快捷键安全性校验

    /// 无法独立构成快捷键的键（回车/Tab/Esc/删除/导航键/方向键）。
    private static let nonShortcutKeyCodes: Set<UInt32> = [
        36, 76,             // Return、小键盘 Return
        48,                 // Tab
        51, 117,            // Backspace、⌦
        53,                 // Escape
        114, 115, 116,      // Help、Home、PageUp
        119, 121,           // End、PageDown
        123, 124, 125, 126, // ←→↓↑
    ]

    /// 校验组合作为全局快捷键是否安全。返回 nil 表示可用；否则返回中文原因（供 UI 直接展示）。
    ///
    /// 拦截两类高风险组合：
    /// - 纯 ⌘ 组合（⌘C/⌘Q/⌘Space…）会在所有应用里遮蔽系统与应用常用操作；
    /// - 仅 ⌥ 的单键组合（⌥E/⌥8…）会破坏其他应用里的特殊字符输入（⌥Space 例外，是本应用默认键）。
    public static func validate(_ spec: HotKeySpec) -> String? {
        if nonShortcutKeyCodes.contains(spec.keyCode) {
            return "回车、Tab、Esc、删除与方向键不能单独作为快捷键"
        }
        // 功能键（F1–F15）任意组合都安全。
        // 必须用键码集合判定：显示名以 "F" 开头的不只有 F1–F15，字母 F 的显示名也是 "F"，
        // 用 hasPrefix 会让裸 F / ⌘F / ⌥F 绕过下面所有拦截（裸 F 会在任何应用里切出启动台）。
        if functionKeyCodes.contains(spec.keyCode) {
            return nil
        }
        if spec.modifiers == 0 {
            return "除功能键外，快捷键至少需要搭配一个修饰键"
        }
        if spec.keyCode == 49 { // Space
            if spec.modifiers == cmdKey {
                return "⌘Space 与系统 Spotlight 冲突，建议加 ⇧ 或换其他组合"
            }
            if spec.modifiers == controlKey {
                return "⌃Space 是系统输入法切换键，不能占用"
            }
            if spec.modifiers == cmdKey | controlKey {
                return "⌃⌘Space 是系统输入法/表情切换键，不能占用"
            }
        }
        if spec.modifiers == cmdKey {
            return "纯 ⌘ 组合会遮蔽应用常用快捷键（如 ⌘C、⌘Q），建议加 ⇧/⌥/⌃"
        }
        if spec.modifiers == optionKey && spec.keyCode != 49 {
            return "仅按 ⌥ 的组合会破坏特殊字符输入（如 ⌥E），建议加 ⇧ 或 ⌘"
        }
        return nil
    }
}
