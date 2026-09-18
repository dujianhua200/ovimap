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

**纯文档改动不触发构建**：`paths-ignore` 里配了 `docs/**` 与 `**/*.md`，
避免为改一行 README 就烧掉一次 CI 额度（macOS runner 计费 ×10）。
代价是：如果某个 tag 指向的提交只改了文档，那次不会自动出包，
需要去 Actions 页面手动 Run workflow。

---

## 3. 产物怎么用

### Windows

1. 下载 `ovimap-windows-x64-3.0.2.zip`，解压到任意目录（**不要**只把 `ovimap.exe`
   单独拖出来，它依赖同级的 `data\` 目录与若干 dll）。
2. 双击 `ovimap.exe` 即可。
3. 如需双击 `.ovimap` 工程文件直接打开，用管理员 PowerShell 跑一次
   `scripts\install_association.ps1` 注册文件关联。

**关于 VC++ 运行库**：Flutter 的 Windows 产物以 `/MD` 动态链接 C 运行库，
`ovimap.exe` 的导入表里含 `MSVCP140.dll` / `VCRUNTIME140.dll` / `VCRUNTIME140_1.dll`，
而 Windows 只自带 UCRT（`api-ms-win-crt-*`），不带这几个。所以打包步骤会从
runner 上 VS 2022 的 `VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT` 目录把整套 VC143
CRT 拷进产物目录，做成真正双击即用的绿色版；该目录不存在时回退到从
`System32` 取这三个必需项。

> 许可提示：这些 dll 属于 Microsoft Visual C++ 可再发行组件，VS 的许可条款允许
> 随你的应用一起分发。若贵司合规口径不允许随包分发，删掉工作流
> 「打包为 zip」步骤里的那段拷贝逻辑即可，代价是用户机器需自行安装
> 「Microsoft Visual C++ 2015-2022 Redistributable (x64)」。

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

### 5.5 Windows 与 macOS 的测试差异

同一套测试在两个平台上的表现**不完全一致**，两类已知差异：

1. **临时目录清理**（已修）：Windows 不允许删除仍被打开的文件。涉及云同步的
   用例在 `tearDown` 里删临时目录时会撞上在途写盘句柄，抛
   `PathAccessException ... errno = 32`。已统一改用 `test/_fs_cleanup.dart`
   里的 `deleteTempDirResilient()`（退让重试、失败只告警），用于
   `restore_confirm_indep_test` / `version_history_indep_test` / `sync_controller_test`。
2. **`HOME` 环境变量**：Windows 上只有 `USERPROFILE`，没有 `HOME`。
   凡是靠 `Platform.environment['HOME']` 定位本机样本的用例，在 Windows 上会
   落到「跳过」（`+500 ~2` 而 macOS 是 `+502 ~1`）。属预期行为，不是失败。

因此**不要用 macOS 本地全绿来推断 Windows 也会绿**，反之亦然。

---

## 6. 验证产物（构建成功 ≠ 产物可用）

```bash
gh run download <run-id> -n ovimap-macos-universal-3.0.2 -D /tmp/art
cd /tmp/art && mkdir x && cd x && ditto -x -k ../ovimap-macos-universal-3.0.2.zip .
lipo -info "ovimap.app/Contents/MacOS/ovimap"        # x86_64 arm64
codesign --verify --strict --verbose=2 ovimap.app    # valid on disk
codesign -d --entitlements - ovimap.app              # 核对 network.client
open ovimap.app                                      # 真启动
```

⚠️ **不要**直接用 `./ovimap.app/Contents/MacOS/ovimap` 跑二进制来验证。
带 app-sandbox 的 app 在**本身已被沙箱限制的 shell** 里直启，会在
`libsystem_secinit` 的 `_libsecinit_appsandbox` 处 SIGTRAP（退出码 133），
并留下 `.ips` 崩溃报告，看起来像应用崩了。判别方法：用同样方式跑
`/System/Applications/Calculator.app/Contents/MacOS/Calculator`，
若它也非零退出（137），就是环境限制；用 `open` 启动才是真实结果。

---

## 7. 本地等价命令

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

---

## 8. 实测结论（2026-09-18）

流水线跑通后，把两个 artifact 都拉回本机核对过：

| 检查项 | 结果 |
|---|---|
| 两个任务 | `Windows x64 打包` 13m12s ✓ / `macOS 打包` 2m35s ✓ |
| macOS 架构 | `lipo -info` → `x86_64 arm64`（真 universal） |
| macOS 签名 | `codesign --verify --strict` → `valid on disk` + `satisfies its Designated Requirement` |
| macOS 权限 | 签名中实际含 `app-sandbox` / `network.client` / `files.user-selected.read-write` |
| macOS 版本 | `CFBundleShortVersionString=3.0.2`、`CFBundleVersion=8`、id `com.dujianhua.ovimap` |
| macOS 可运行 | `open ovimap.app` → 进程稳定存活 13 秒以上，无新崩溃报告 |
| macOS 体积 | .app 53 MB，zip 21 MB |
| Windows 内容 | 20 个条目：`ovimap.exe` + `flutter_windows.dll` + `dartjni.dll` + 4 个插件 dll + `data/`；解压后 33.7 MB，zip 13 MB |
| 本地测试 | `flutter test` 502 通过 / 1 跳过 / 0 失败 |

Windows 包的**真实启动**未在本机验证（本机没有 Windows），
只核对了导入表与文件完整性；首次真机运行时如报缺 dll，请看 §3 的运行库说明。

---

## 9. 成本提醒

private 仓库的 GitHub Actions 免费额度是 **2000 分钟/月**，且计费带倍率：

| runner | 倍率 | 本项目单次约耗 |
|---|---|---|
| `windows-latest` | ×2 | ~13 分钟 → 计费 ~26 分钟 |
| `macos-latest` | ×10 | ~2.6 分钟 → 计费 ~26 分钟 |

即**一次双平台构建约消耗 50 分钟额度，每月大约 40 次**。
如果构建频次高，可以：

- 把仓库改为 public（Actions 分钟数不限）；
- 或删掉工作流里的 `unit test` 步骤减少耗时（不推荐，会失去门禁）；
- 或把 macOS 任务改成只在打 tag 时跑（加 `if: startsWith(github.ref, 'refs/tags/v')`）。

---

## 10. 发布版本（GitHub Release）

### 10.1 自动路径（推荐，产物可溯源）

打 `v*` 标签 → 工作流在构建成功后调用 `softprops/action-gh-release@v2`
把两个 zip 挂到该标签对应的 Release 上：

```bash
git tag v3.0.2
git push origin v3.0.2
```

工作流里两个任务各有一段：

```yaml
- name: 挂到 Release（仅打 v* 标签时）
  if: startsWith(github.ref, 'refs/tags/v')
  uses: softprops/action-gh-release@v2
  with:
    files: ovimap-windows-x64-${{ env.BUILD_NAME }}.zip   # macOS 任务为 universal 那个
    fail_on_unmatched_files: true
```

`fail_on_unmatched_files: true` 是刻意的：**产物没生成就报错**，避免出现
「Release 建好了但资产是空的」这种静默失败。

### 10.2 手动路径（不等 CI，用已验证的本地包）

手边已有验证过的 `dist/` 压缩包、又不想等一次完整 CI 时：

```bash
gh release create v3.0.2 \
  dist/ovimap-windows-x64-3.0.2.zip \
  dist/ovimap-macos-universal-3.0.2.zip \
  --title "滑洲云图 ovimap v3.0.2 桌面版" \
  --notes-file release-notes-v3.0.2.md
```

注意：`gh release create` 会在远端**创建同名标签**，而标签推送会再次触发工作流
（GitHub 的 `paths-ignore` 过滤器对标签推送不生效）。两条路径不冲突 ——
CI 重新构建后会以同名资产覆盖上传，等于给该版本补一次「云端可复现」验证；
若 CI 因为偶发用例失败，已上传的本地包仍在，Release 不会变空。

补传 / 替换资产：

```bash
gh release upload v3.0.2 dist/*.zip --clobber
```

### 10.3 已发布版本记录

| 标签 | 日期 | 内容 |
|---|---|---|
| `v3.0.2` | 2026-09-18 | 首个桌面稳定版：Windows x64 绿色版 + macOS universal，对应 `pubspec.yaml` 的 `3.0.2+8` |

### 10.4 版本号从哪来

`pubspec.yaml` 的 `version: <name>+<number>` 是唯一真源，工作流开头用一段
`Select-String`（Windows）/ `grep+sed`（macOS）解析出 `BUILD_NAME` 与 `BUILD_NUMBER`，
再传给 `flutter build --build-name --build-number`。
**升级版本时只改 `pubspec.yaml` 这一处**，标签名与产物文件名会自动跟上。

