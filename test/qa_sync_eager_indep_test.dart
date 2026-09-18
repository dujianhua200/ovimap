// QA 独立护栏（批次五）：验证移动端启动即创建 SyncController（provider `lazy: false`）。
//
// 背景：移动端 HomePage.build 不读 SyncController（同步 UI 仅在抽屉/设置里），
// ChangeNotifierProvider 若用默认 `lazy: true`，`create` 不会在启动时触发，
// 导致 attachSyncController/start() 都不跑 → 「已配置设备冷启动不自动同步」。
//
// 本测试不复用源级字符串断言（那易写成同义反复），而是**真正 pump 真实 OviMapApp**，
// 从 HomePage 子树取 AppState，断言 syncController 已被接线。这是端到端行为护栏。
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:ovimap/main.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/home_page.dart';

void main() {
  // 仅移动端壳有意义（Windows 走 WorkspacePage，其 build 本就 watch 会触发创建）。
  testWidgets('移动端启动即创建并接线 SyncController（eager, lazy:false）',
      skip: Platform.isWindows, (tester) async {
    await tester.pumpWidget(const OviMapApp());
    // 让首帧与 provider 建立完成。
    await tester.pump(const Duration(milliseconds: 50));

    // 测试宿主为 macOS → Platform.isWindows=false → 走移动端 HomePage 壳。
    expect(find.byType(HomePage), findsOneWidget,
        reason: '非 Windows 平台应挂载移动端 HomePage');

    final ctx = tester.element(find.byType(HomePage));
    final st = Provider.of<AppState>(ctx, listen: false);

    // 关键断言：HomePage 从不读 SyncController，但启动即应已创建并接线。
    expect(st.syncController, isNotNull,
        reason: 'SyncController provider 必须 eager（lazy:false）——'
            '否则移动端冷启动不会自动同步');
  });
}
