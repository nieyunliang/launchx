import AppKit
import LaunchXCore

// LaunchX 入口：菜单栏常驻后台应用（LSUIElement，Dock 图标按设置动态开关）。
let app = NSApplication.shared
let delegate = LaunchXCore.AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
