import 'dart:io' show Platform;

/// 平台能力探测（单点收口）。
///
/// 业务代码判断平台能力时统一走这里，**禁止**散落 `Platform.isWindows`。
/// 桌面端的三处降级由本类驱动：
/// - 无 GPS（`hasGps=false`）→ 不订阅位置流，打点走手动落点；
/// - 无罗盘（`hasCompass=false`）→ 不订阅 `flutter_compass`（其无 Windows 实现，
///   调用会抛 `MissingPluginException`），罗盘控件隐藏；
/// - 无相机（`hasCamera=false`）→ 拍照入口降级为「选文件」。
class PlatformCaps {
  PlatformCaps._();

  /// 是否桌面平台（Windows / Linux / macOS）。
  static final bool isDesktop =
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 是否有真实 GPS 定位（桌面默认无）。
  static bool get hasGps => !Platform.isWindows;

  /// 是否有电子罗盘。`flutter_compass` 仅 iOS/Android 有实现。
  static bool get hasCompass => Platform.isAndroid || Platform.isIOS;

  /// 是否有相机拍摄能力。`image_picker` 的 `ImageSource.camera` 仅移动端支持。
  static bool get hasCamera => Platform.isAndroid || Platform.isIOS;

  /// 是否支持系统「另存为」对话框（`file_picker.saveFile`）。
  static bool get supportsFileSaveDialog => Platform.isWindows;
}
