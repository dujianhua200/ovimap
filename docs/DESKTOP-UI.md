# 桌面界面设计说明（DESKTOP-UI）

> 适用范围：Windows / macOS / Linux 桌面壳（`lib/ui/desktop/`）。
> 设计参照：**奥维互动地图桌面版**（下称「奥维桌面版」）的布局与交互口径。
> 相关文档：[BUILD-windows.md](BUILD-windows.md) · [BUILD-macos.md](BUILD-macos.md) · [USAGE.md](USAGE.md)

---

## 0. 一句话结论

**桌面端不是移动端的放大版。** 它有一套独立的 Chrome（菜单栏 / 工具栏 / 三栏 / 提示栏 / 状态栏）和一套独立的地图交互口径，只在「业务核心 + 数据模型 + 共享图层构建」这三层与移动端复用同一份代码。

把手机竖屏界面拉宽塞进桌面窗口，是 2026-09 那一版 macOS 包「界面变形严重、地图缩放不管用」的直接原因。本文记录问题根因、修复位置，以及桌面端相对奥维桌面版**对齐了什么、刻意不一样的是什么、为什么**。

---

## 1. 问题 → 根因 → 修复

| 现象（用户反馈） | 根因 | 修复位置 |
|---|---|---|
| macOS「界面变形严重，不能按照手机的界面来设计电脑的界面」 | `main.dart` 用 `Platform.isWindows` 挑壳，**macOS 被判成移动端**，落到 `HomePage` 移动竖屏壳；宽窗口下底部条、抽屉、竖排工具栏全被拉变形 | `lib/main.dart`：改用 `PlatformCaps.isDesktop` |
| macOS 上窗口方向被锁竖屏 | 竖屏锁的判据同样是 `Platform.isWindows` | `lib/main.dart`：`!PlatformCaps.isDesktop` 才锁竖屏 |
| 窗口只有 800×600，三栏被挤成一团 | `flutter create` 模板的 `MainMenu.xib` 默认尺寸，Dart 侧无法覆盖 | `macos/Runner/MainFlutterWindow.swift`：1440×900，最小 1024×680，并按可见屏幕收敛 + 居中 |
| macOS「地图缩放不管用」 | macOS 跑的是移动壳，而 `MapCanvas` 的**默认** flags 是移动口径（`pinchZoom\|drag\|doubleTapZoom\|rotate`），**不含 `scrollWheelZoom`** → 滚轮完全没接线。（Windows 之所以能滚，是因为旧桌面壳额外传了 `InteractiveFlag.all`。） | `lib/ui/map/map_canvas.dart`：默认值收口到 `defaultFlagsForCurrentPlatform()`；桌面壳**不再覆盖** |
| 按住 Ctrl 移动鼠标时地图被转掉，Ctrl+Z/S/E 顺手把图转歪 | flutter_map 的 `CursorKeyboardRotationOptions` 默认把 Control 键当旋转触发键，与桌面快捷键直接冲突 | `lib/ui/map/map_canvas.dart`：桌面用 `CursorKeyboardRotationOptions.disabled()` |
| `Platform.isWindows` 散落各处，改一处漏一处 | 平台能力判断没有单点收口 | `lib/services/platform_caps.dart`：`isDesktop` / `hasGps` / `hasCompass` / `hasCamera` / `supportsFileSaveDialog` |

> **教训**：平台分支只有一处（`main.dart`），平台能力只有一处（`PlatformCaps`）。
> 新增平台相关判断时一律走 `PlatformCaps.isDesktop`，**不要写单一平台的 `isXxx`** ——
> `hasGps` 曾经写成 `!Platform.isWindows`，把 macOS / Linux 误判成「有 GPS」，
> 这类错误在移动端跑不出来、只在桌面端炸。

---

## 2. 与奥维桌面版的对照表

| 奥维桌面版的做法 | 本应用 | 状态 |
|---|---|---|
| 顶部菜单 + 工具栏 | 菜单栏（文件 / 编辑 / 工程 / 底图 / 同步 / 帮助）+ 图标工具栏 | ✅ 对齐 |
| 左侧「收藏夹」面板：目录树 + 逐项控制显隐 | 左栏：文件夹树 + 工程列表，每项右侧「显示到地图 / 从地图隐藏」按钮 | ✅ 语义对齐（用图标按钮而非复选框，见 §6） |
| 中央地图 | 中央地图（含比例尺、右键菜单、业务符号图层） | ✅ 对齐 |
| 右侧属性面板 | 右栏：选中点位的属性编辑 + 来源工程 | ✅ 对齐 |
| 底部状态栏：**鼠标指针处经纬度** + 显示级别 + 坐标系 | 状态栏：鼠标经纬度 + 视图中心 + 图源 + 缩放级别 + 选中数 + 同步态 + 坐标系 | ✅ 对齐 + 增强 |
| 模式提示栏（当前操作提示） | 提示栏：模式胶囊 + 键盘提示 + 实时数据 + 「完成 (Esc)」 | ✅ 对齐 |
| 滚轮缩放以**鼠标指针为锚点** | flutter_map `scrollWheelZoom` 原生以指针为锚 | ✅ 对齐 |
| 左键拖动平移 | `InteractiveFlag.drag` | ✅ 对齐 |
| 方向键微移地图 | flutter_map `KeyboardOptions.enableArrowKeysPanning`（默认开） | ✅ 对齐 |
| 右键上下文菜单 | `onSecondaryTap` → 地图上下文菜单 | ✅ 对齐 |
| 双击结束折线绘制 | **不采用**，结束动作交给 `Esc` 与提示栏「完成」 | ⚠️ 有意差异，理由见 §4 |
| 双击缩放 | **桌面不启用** | ⚠️ 有意差异，同上 |

---

## 3. 桌面 Chrome 的组成与尺寸

自下而上（`lib/ui/desktop/workspace_page.dart` 的 `Column`）：

| 部件 | 文件 | 高度 | 说明 |
|---|---|---|---|
| 菜单栏 | `app_menu_bar.dart` | 自适应 | 6 组菜单：文件 / 编辑 / 工程 / 底图 / 同步 / 帮助 |
| 工具栏 | `toolbar.dart` | 自适应 | 打点 · 连线 · 测距 · 轨迹 · 定位 · 撤销 · 重做 · 删除 · 缩放 ± · 图源 · 导出 · 同步 · 折叠左右栏 |
| 三栏主体 | `left_panel / map / right_panel` | `Expanded` | 左 260（可拖到 200–420）、右 300（可拖到 240–460），分隔条可拖拽 |
| **模式提示栏** | `workspace_page._hintBar` | **30** | 新增。模式胶囊 + 操作提示 + 实时数据 + 「完成 (Esc)」 |
| 状态栏 | `status_bar.dart` | 26 | 设备 · 同步 · 最后同步时间 · **鼠标经纬度** · 视图中心 · 图源 · 缩放 · 选中数 · 坐标系 |

**窗口下限**：1024×680（与 Windows 侧 `win32_window.cpp` 的 `WM_GETMINMAXINFO`、macOS 侧 `MainFlutterWindow.contentMinSize` 一致）。
窗口宽 < 1180 时右栏自动收起（`_body` 里的阈值），避免挤压地图。

---

## 4. 地图交互口径（flags）

`lib/ui/map/map_canvas.dart` → `defaultFlagsForCurrentPlatform()`

| 能力 | 移动 | 桌面 | 原因 |
|---|---|---|---|
| `drag` 平移 | ✅ | ✅ | 桌面为左键拖拽 |
| `scrollWheelZoom` 滚轮缩放 | — | ✅ | **桌面缩放的主力入口**，缺了滚轮就没反应 |
| `doubleTapZoom` 双击放大 | ✅ | ❌ | 见下方「250ms 代价」 |
| `pinchZoom` 双指缩放 | ✅ | ❌ | 桌面无多指；触控板双指滚动已由 `scrollWheelZoom` 覆盖 |
| `rotate` 旋转 | ✅ | ❌ | 出图要求正北朝上；且旋转会抢右键菜单 / 框选事件 |
| `flingAnimation` 惯性滑动 | ❌ | ❌ | 测绘要「停手即停」，惯性会让定点对不准 |

### 4.1 桌面为什么不启用双击缩放：单击会被延迟 250ms

flutter_map 的点击判定在 `PositionedTapDetector2`（`gestures/positioned_tap_detector_2.dart`）：

```dart
static const _defaultDelay = Duration(milliseconds: 250);   // 双击判定窗口
static const _doubleTapMaxOffset = 48.0;                    // 双击的最大像素偏移
...
void _onTapEvent() {
  if (widget.onDoubleTap == null) {
    _postCallback(pending, widget.onTap);   // 立刻回调：零延迟
  } else {
    _sink.add(pending);                     // 进流，等 250ms 超时才算「单击」
  }
}
```

而 `MapInteractiveViewer` 只在 flags 含 `doubleTapZoom` 时才给 `onDoubleTap` 传值
（`InteractiveFlag.hasDoubleTapZoom(flags) ? ... : null`）。

**结论：开双击缩放 = 每一次单击落点都要等 250ms 才发生。**

对本应用（现场打点，一条线要点几十上百下）这个延迟是硬伤。因此桌面端主动关闭双击缩放，
改用**四条缩放通道**：滚轮 / `Ctrl±`（含裸 `+` `-`）/ 工具栏缩放按钮 / 方向键微移。

移动端维持原有口径不动 —— 改它会牵动既有手感与整轮回归，收益不成正比。

### 4.2 与奥维「双击结束绘制」的有意差异

奥维的连续画线有「绘制中」状态机，双击是自然的收尾手势。本应用**没有**连续画线状态：
每次单击独立落点，杆路链是由点位自动串起来的。因此：

- 结束动作 = `Esc` / 提示栏「完成」按钮；
- 全部模式都**不需要**延迟单击去等待第二次点击，落点手感是即时的。

代价是少了奥维那一下双击；换来的是打点零延迟。这是一次刻意的取舍，不是缺项。

---

## 5. 快捷键

实现：`lib/ui/desktop/shortcuts.dart`（`Shortcuts` + `Actions` + `Intent`，零新依赖）。

| 键 | 作用 | 生效条件 |
|---|---|---|
| `Ctrl+S` / `⌘S` | 保存工程 | 始终 |
| `Ctrl+Z` / `⌘Z` | 撤销 | 始终 |
| `Ctrl+Y` / `Ctrl+Shift+Z` / `⌘⇧Z` | 重做 | 始终 |
| `Ctrl+E` / `⌘E` | 打开导出中心 | 始终 |
| `Ctrl+F` / `⌘F` | 聚焦左栏搜索 | 始终 |
| `Ctrl+O` / `⌘O` | 打开 `.ovimap` 工程 | 始终 |
| `Ctrl` + `=` / `+` 、`⌘±` | 放大一级 | 始终 |
| `Ctrl` + `-` 、`⌘−` | 缩小一级 | 始终 |
| `Ctrl+0` / `⌘0` | 复位到启动视图 | 始终 |
| `+` `=` `-`（含小键盘） | 放大 / 缩小一级 | **非文本编辑态** |
| `0`（含小键盘） | 复位到启动视图 | 非文本编辑态 |
| `Esc` | 取消当前操作 / 结束模式 | 非文本编辑态 |
| `Backspace` | 退掉最后一个点 / 最后一条连线 | 非文本编辑态 |
| `Delete` | 删除选中点 | 非文本编辑态 |

### 5.1 为什么裸键要按「是否在编辑文本」开关

`Shortcuts` 沿焦点链**由内向外**冒泡，而 `DesktopShortcuts` 位于 `WidgetsApp` 的
`DefaultTextEditingShortcuts` **内侧**（更靠近焦点）。也就是说，只要无条件注册
`Delete` / `Backspace` / `+` / `-`，文本框内的「向后删除 / 退格 / 输入 +−」就会被这一层截胡 ——
左栏搜索框、属性对话框全都失灵。

所以裸键表随「当前主焦点是否落在 `EditableText` 子树内」动态开关
（`FocusManager` 是 `ChangeNotifier`，焦点变化时只 `setState` 本组件；
`child` 是同一个 Widget 实例，Element 复用，**不会**连地图一起重建）。
带修饰键的条目（Ctrl/⌘ 组合）不参与开关，始终生效。

---

## 6. 状态栏的「鼠标经纬度」为什么用 ValueNotifier

`onPointerHover` 在鼠标移动时按帧触发。若把它接到壳的 `setState`，
整个 `WorkspacePage`（含 `MapCanvas`）会跟着重建 —— 直接拖垮滚轮缩放和拖拽平移的手感。

做法（`workspace_page._onMouseGeo` → `status_bar`）：

1. `MapCanvas.onPointerGeo` 回传 **WGS-84**（显示基准的换算只做一次，且由壳负责）；
2. 壳把 WGS-84 换成当前显示基准并格式化，**只有格式化文本真的变化时**才写
   `ValueNotifier<LatLng?>`（按像素去重，避免每帧一次通知）；
3. `StatusBar` 内部用 `ValueListenableBuilder` 局部监听，只有那一个文本节点重建。

鼠标移出地图 → 回传 `(null, null)` → 状态栏显示「鼠标 ——」。

---

## 7. 模式提示栏的内容口径

`workspace_page._hintContent`，与移动端底部条同源同口径（同一套模式枚举、同一套统计），只是排布按桌面横屏重排。

| 模式 | 胶囊 | 操作提示 | 右侧实时数据 |
|---|---|---|---|
| 采集（edit） | 采集中·{当前符号} | 左键落点 · Backspace 退点 · Ctrl+Z 撤销 · Delete 删除选中 · Ctrl+S 保存 | n 点 · 已连 X / Y 段 |
| 待定放置 | 待定放置 | 点地图把该点放到新位置 · Esc 取消 | — |
| 测距 | 测距 | 左键加点 · Backspace 退点 · 完成 (Esc) 结束测量 | 总长 / n 点 |
| 测面积 | 测面积 | 左键加顶点 · Backspace 退点 · 完成 (Esc) 结束测量 | 面积 / n 点 |
| 拓扑连线 | 拓扑连线 | 点起点箱体 → 点终点箱体 · Backspace 退一条连线 · 完成 (Esc) 结束 | 已连 n / m 个箱体 |
| 框选 | 框选 | 在地图上拖出矩形选择点位 · 完成 (Esc) 退出框选 | 已选 n 点 |
| 普通（view） | 普通 | 左键点选点位（右栏看属性）· 平移/缩放/右键/快捷键提示 | 已选 n 点 |
| 轨迹中 | 轨迹中 | 桌面端无 GPS，请在移动端沿线走查录制 | — |

`Esc` 的优先级（从「最临时」到「最正式」）：
**待定点位编辑 → 清空选择 → 退出框选 / 测量 / 连线**。
`Esc` **不清空草稿** —— 误触丢几十个点是不可接受的，清空草稿有专门入口（菜单 / 右键）。

---

## 8. 已知差异与后续项

| 项 | 现状 | 若要完全对齐奥维 |
|---|---|---|
| 左栏显隐控件 | 眼睛图标按钮（`st.toggleVisible`） | 换成 `Checkbox` 即可，语义已一致，纯粹是视觉差异 |
| 改点位靠对话框 | 「右键 → 待点放置 → 左键落点」 | 奥维是点住手柄直接拖；需要新增屏幕手柄命中层 |
| 触控板双指捏合缩放 | 不支持（双指滚动已能缩放） | 加 `InteractiveFlag.pinchZoom`，需先验证与 `drag` 的事件竞争 |
| 桌面端轨迹录制 | 明确不支持（无 GPS） | 保持：桌面端本就不具备定位硬件 |

---

## 9. 验证清单（改桌面 UI 后必跑）

```bash
# 静态分析：0 error / 0 warning（info 允许）
flutter analyze --no-fatal-infos

# 测试（⚠️ 本机常开代理，必须绕开，否则 flutter_tester 的本地 WebSocket 会被代理吃掉）
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 flutter test

# 本地跑桌面壳
flutter run -d macos      # 或 -d windows
```

人工过一遍：滚轮缩放（以指针为锚）/ 左键拖动平移 / 右键菜单 / `Ctrl+0` 复位 /
`Esc` 结束模式 / `Backspace` 退点 / 状态栏鼠标经纬度随鼠标走动 /
文本框内退格与 `+-` 正常输入（第 5.1 节的回归点）。
