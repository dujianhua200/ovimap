import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 强制深色外观（Dark Aqua）。
  ///
  /// 为什么必须在**宿主**而不是 Flutter 侧设：应用内容区是 Flutter 画的，主题
  /// 早就是深色（`lib/main.dart` 的 `Brightness.dark` + 底色 `0xFF101418`）。
  /// 用户看到的「白色」来自 **macOS 系统外壳** —— 屏幕顶部的系统菜单栏与窗口
  /// 标题栏跟随**系统外观**，系统是浅色模式时它们就是白的，于是和深色内容区割裂。
  /// macOS 的规则是：应用处于前台时，系统菜单栏采用**该应用**的外观；
  /// 所以把 `NSApp.appearance` 钉成 `darkAqua`，顶部菜单栏与标题栏会一起变深。
  ///
  /// 放在 `applicationWillFinishLaunching` 而不是 `didFinishLaunching`：
  /// 前者早于窗口与菜单的首次绘制，才不会在启动瞬间闪一下白色。
  override func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.appearance = NSAppearance(named: .darkAqua)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
