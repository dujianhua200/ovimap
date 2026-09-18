// QA 独立护栏（批次五）：验证启动即创建 SyncController（provider `lazy: false`）。
//
// 背景：移动端 HomePage.build 不读 SyncController（同步 UI 仅在抽屉/设置里），
// ChangeNotifierProvider 若用默认 `lazy: true`，`create` 不会在启动时触发，
// 导致 attachSyncController/start() 都不跑 → 「已配置设备冷启动不自动同步」。
//
// 本测试不复用源级字符串断言（那易写成同义反复），而是**真正 pump 真实 OviMapApp**，
// 从当前平台的界面壳子树取 AppState，断言 syncController 已被接线。这是端到端行为护栏。
//
// ⚠️ 壳的选择由 `PlatformCaps.isDesktop` 决定（macOS 也是桌面壳），
// 因此这里按平台取**实际挂载**的壳，而不是写死 HomePage —— 否则本机（macOS）
// 一旦改走桌面壳，这条护栏就会因为「找不到 HomePage」而误报失败。
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:ovimap/main.dart';
import 'package:ovimap/services/platform_caps.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/desktop/workspace_page.dart';
import 'package:ovimap/ui/home_page.dart';

void main() {
  testWidgets('启动即创建并接线 SyncController（eager, lazy:false）', (tester) async {
    await tester.pumpWidget(const OviMapApp());
    // 让首帧与 provider 建立完成。
    await tester.pump(const Duration(milliseconds: 50));

    final desktop = PlatformCaps.isDesktop;
    final finder = find.byType(desktop ? WorkspacePage : HomePage);
    expect(finder, findsOneWidget,
        reason: desktop ? '桌面平台应挂载 WorkspacePage' : '移动平台应挂载 HomePage');

    final ctx = tester.element(finder);
    final st = Provider.of<AppState>(ctx, listen: false);

    // 关键断言：移动端壳从不读 SyncController，但启动即应已创建并接线。
    expect(st.syncController, isNotNull,
        reason: 'SyncController provider 必须 eager（lazy:false）——'
            '否则冷启动不会自动同步');
  });
}
