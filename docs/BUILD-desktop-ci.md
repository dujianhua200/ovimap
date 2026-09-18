# 滑洲云图 ovimap —— GitHub Actions 双平台构建说明

> 面向：想拿 Windows / macOS 安装包，但手边没有对应机器的使用者。
> 目标：推一次代码 → 云端出两个压缩包 → 下载即用。

---

## 0. 一句话流程

推代码 / 手动触发 → Actions 里等两个任务变绿 → 在该次运行的 **Artifacts** 区下载
`ovimap-windows-x64-<版本>.zip` 与 `ovimap-macos-universal-<版本>.zip`。

---

## 1. 流水线结构

工作流文件：`.github/workflows/build-desktop.yml`

| 任务 | 运行环境 | 干什么 | 产物 |
|---|---|---|---|
| `build-windows` | `windows-latest` | analyze + test 门禁 → `flutter build windows --release` → zip | `ovimap-windows-x64-3.0.2.zip` |
| `build-macos` | `macos-latest` | analyze + test 门禁 → `flutter build macos --release` → ditto 打包 | `ovimap-macos-universal-3.0.2.zip` |

**两个任务各自独立跑测试**，而不是共用一个 Linux 测试任务。原因：
`test/platform_caps_test.dart`、`test/desktop_shell_wiring_test.dart` 等用例的断言
是按平台参数化的，Linux 全绿并不能证明 Windows / macOS 也绿。

**门禁规则**：静态分析或单元测试任一失败 → 该平台不出包。
`flutter analyze` 加了 `--no-fatal-infos`，只放行 **info** 级 lint（当前 68 条，
多为测试脚本里的 `print`）；**error 与 warning 仍然会让构建失败**。想收紧就删掉这个参数。

---

## 2. 触发方式

| 场景 | 做法 |
|---|---|
| 日常验证 | push 到 `main` / `master` |
| 提 PR | 自动跑，作为合并前检查 |
| 不想改代码只想出包 | Actions → 左侧「桌面端构建（Windows / macOS）」→ Run workflow |
| 发版 | 打 `v*` 标签（如 `v3.0.2`）→ 除 artifact 外，还会自动把两个 zip 挂到 GitHub Release |

```bash
git tag v3.0.2
git push origin v3.0.2
```

---

## 3. 产物怎么用

### Windows

1. 下载 `ovimap-windows-x64-3.0.2.zip`，解压到任意目录（**不要**只把 `ovimap.exe`
   单独拖出来，它依赖同级的 `data\` 目录与若干 dll）。
2. 双击 `ovimap.exe` 即可。这是免安装绿色版，无需安装运行库。
3. 如需双击 `.ovimap` 工程文件直接打开，用管理员 PowerShell 跑一次
   `scripts\install_association.ps1` 注册文件关联。

### macOS

1. 下载 `ovimap-macos-universal-3.0.2.zip`，解压得到 `ovimap.app`，拖入「应用程序」。
2. **首次打开会被 Gatekeeper 拦**：包是 ad-hoc 签名的（没有 Apple 开发者证书），
   系统会提示「无法验证开发者」。任选其一放行：
   - 右键 `ovimap.app` → 「打开」→ 在弹窗里再点「打开」（只需一次）；
   - 或终端执行 `xattr -cr /Applications/ovimap.app`。
3. 架构是 universal（arm64 + x86_64），Apple Silicon 与 Intel 都能跑。

> 想让包变成「双击即开、无任何提示」，需要 Apple Developer 付费账号
> （$99/年）做 Developer ID 签名 + 公证。当前没有配证书，因此走 ad-hoc。

---

## 4. 手动改配置

| 想改什么 | 改哪里 |
|---|---|
| Flutter 版本 | 工作流顶部 `env.FLUTTER_VERSION`（当前 `3.47.2`，与 `docs/BUILD-windows.md` 基线一致） |
| artifact 保留天数 | 各任务 `upload-artifact` 的 `retention-days`（当前 30 天） |
| 任务超时 | 各任务 `timeout-minutes`（Windows 60 分钟 / macOS 90 分钟） |
| 关掉发版挂载 | 删掉两个 `挂到 Release` 步骤 |

---

## 5. 已知边界（重要）

### 5.1 macOS 端目前是「移动壳」界面

`lib/main.dart` 的顶层平台判断是：

```dart
home: Platform.isWindows ? const WorkspacePage() : const HomePage(),
```

macOS 不属于 `isWindows`，因此会落到移动竖屏壳（`HomePage`），并且
`SystemChrome.setPreferredOrientations` 会按移动端约束方向。也就是说：
**macOS 包能构建、能打开、能跑业务逻辑，但界面不是桌面三栏布局。**

要改成真正的桌面版，把这两处判断换成 `PlatformCaps.isDesktop` 即可 ——
`PlatformCaps.isDesktop` 已经包含 `Platform.isMacOS`，`lib/services/loc.dart`
也早就按 `isDesktop` 做了无 GPS 降级。本次按「最小可运行」范围没有动它。

### 5.2 macOS 端部分桌面能力仍是降级路径

`PlatformCaps.supportsFileSaveDialog` 当前写死 `Platform.isWindows`（`file_picker`
的 `saveFile` 在 macOS 上其实可用）。所以 macOS 里导出走的是「分享/落盘到数据目录」
路径，而不是系统「另存为」对话框。同样归入 5.1 的待办。

### 5.3 `flutter analyze` 现有 68 条 info

不是本次引入的，是仓库既有状态（`drawer_panel.dart` 的
`use_build_context_synchronously`、测试与 `tool/` 里的 `avoid_print` 等）。
CI 里已放行 info 级，不影响出包。

### 5.4 桌面构建与 Android 侧无关

两个任务都不会触发 Gradle，因此不受 `dependency_overrides`
（`flutter_plugin_android_lifecycle: 2.0.22`）与 AGP 9 相关约束的影响。

> 提示：`android/.gitignore` 里忽略了 `gradle-wrapper.jar` 与 `gradlew`。
> 如果以后想给 Android 也加云端构建，需要注意新克隆的仓库缺 wrapper，
> 得先本地跑一次构建或把这些文件补进版本库。

---

## 6. 本地等价命令

想在本地复现 CI 的动作（macOS 需装完整 Xcode）：

```bash
export NO_PROXY="127.0.0.1,localhost,::1"   # 本机若走 HTTP 代理，必须加这行
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build macos --release                 # 或 flutter build windows --release
```

`NO_PROXY` 那行是本机环境特有的：本地 shell 配了 `HTTP_PROXY=127.0.0.1:xxxxx`，
会把 `flutter_tester` 与测试进程之间的 localhost WebSocket 当成外网请求劫持，
表现为所有用例加载失败并报 `Invalid WebSocket upgrade request`。
GitHub 的 runner 没有代理，不需要这行。
