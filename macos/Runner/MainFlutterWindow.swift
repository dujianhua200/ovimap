import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 桌面壳的目标初始尺寸（与 Windows 侧 `windows/runner/main.cpp` 的 1440×900 对齐）。
  ///
  /// 为什么必须显式设置：`flutter create` 模板生成的 MainMenu.xib 里窗口只有
  /// 800×600，而桌面三栏布局（左栏 260 + 地图 + 右栏 300）在该宽度下会被挤成一团 ——
  /// 这是「界面变形严重」的直接成因之一。窗口尺寸归窗口管，UI 侧的自适应只做兜底。
  private static let preferredSize = NSSize(width: 1440, height: 900)

  /// 最小尺寸与 Windows 侧 `win32_window.cpp` 的 WM_GETMINMAXINFO 限制保持一致，
  /// 低于此尺寸三栏壳无法正常排布。
  private static let minimumSize = NSSize(width: 1024, height: 680)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 屏幕可能比目标尺寸小（如 1280×800 的笔记本）：按可见区域收敛，避免窗口超出屏幕。
    let target = MainFlutterWindow.preferredSize
    if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      self.setContentSize(NSSize(width: min(target.width, visible.width),
                                 height: min(target.height, visible.height)))
    } else {
      self.setContentSize(target)
    }
    self.contentMinSize = MainFlutterWindow.minimumSize
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
