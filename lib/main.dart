import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'sync/sync_controller.dart';
import 'ui/desktop/workspace_page.dart';
import 'ui/home_page.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // 移动端保持竖屏；桌面端（Windows）不加方向约束，允许 1024×680 起的任意窗口尺寸。
  if (!Platform.isWindows) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
  runApp(OviMapApp(startupProjectPath: startupProjectFromArgs(args)));
}

/// 从启动参数里解析 `.ovimap` 工程文件路径（T22 文件关联：`ovimap.exe "xxx.ovimap"`）。
///
/// Windows 的 runner 已把命令行参数经 `set_dart_entrypoint_arguments` 传入 Dart；
/// 这里只挑出第一个以 `.ovimap` 结尾的参数（去掉可能的包裹引号）。无则返回空串。
String startupProjectFromArgs(List<String> args) {
  for (final raw in args) {
    var a = raw.trim();
    if (a.length >= 2 && a.startsWith('"') && a.endsWith('"')) {
      a = a.substring(1, a.length - 1).trim();
    }
    if (a.toLowerCase().endsWith('.ovimap')) return a;
  }
  return '';
}

class OviMapApp extends StatelessWidget {
  const OviMapApp({super.key, this.startupProjectPath = ''});

  /// 启动时自动导入并打开的 `.ovimap` 工程文件路径（空串表示无）。
  final String startupProjectPath;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>(
          create: (_) => AppState(startupProjectPath: startupProjectPath)..init(),
        ),
        // 云同步编排器（T15/T16）：单个 `SYNC_TOKEN` 单用户多设备，不做账号体系。
        // 与 AppState 通过回调接线（`AppState.attachSyncController`），避免循环依赖。
        //
        // ⚠️ `lazy: false` 必须！移动端 `HomePage` 启动时不读 `SyncController`
        // （同步 UI 仅在抽屉/设置里），若用默认惰性，`create` 不触发 → `start()`
        // 与 `attachSyncController` 都不会跑，导致「已配置设备冷启动不自动同步」。
        // 桌面端 `WorkspacePage` 于 build 中 watch 会触发，但显式 `lazy: false`
        // 让两端一致地在启动即起同步。
        ChangeNotifierProvider<SyncController>(
          lazy: false,
          create: (ctx) {
            final st = ctx.read<AppState>();
            final sc = SyncController(store: st.store);
            st.attachSyncController(sc);
            // 启动同步（异步，不阻塞首帧；未配置令牌时静默保持本地模式）。
            scheduleMicrotask(sc.start);
            return sc;
          },
        ),
      ],
      child: MaterialApp(
        title: '滑洲云图',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: false,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF101418),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF40C4FF),
            secondary: Color(0xFF69F0AE),
          ),
        ),
        // 平台分支（架构文档 §3.1）：Windows → 桌面三栏壳；其余 → 移动竖屏壳。
        // 唯一顶层平台判断点；业务代码内平台能力一律走 PlatformCaps。
        home: Platform.isWindows ? const WorkspacePage() : const HomePage(),
      ),
    );
  }
}
