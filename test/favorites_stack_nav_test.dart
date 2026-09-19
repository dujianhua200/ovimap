// 收藏夹叠加式多级导航护栏（v3.4.0 用户反馈：「收藏夹最好用叠加功能来实现
// 多级文件夹的访问」）。
//
// 验收口径：
//   · 列表**只显示当前层**——子文件夹 + 当前层工程，不平铺整棵树；
//   · 点文件夹钻入该层；「..」返回上级；面包屑可跳回任意上级/根；
//   · 搜索时跨全库（不受当前层限制）。
//
// 真实文件 I/O 用 `tester.runAsync`（widget 测试是假时钟），数据准备完后
// 钻入/返回是纯 setState，不需要 runAsync。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/sync/sync_controller.dart';
import 'package:ovimap/ui/desktop/left_panel.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fs_cleanup.dart';

final store = LabelStore.instance;

void main() {
  late Directory dir;
  late AppState st;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ovimap_fav_stack_nav');
    store.setBaseDirForTest(dir);
    // 根工程 P2；文件夹 A（内含工程 P1 与子文件夹 B）。
    await store.finishCollection(
        name: 'P2', kind: 'label', folderId: '', editMode: 'design', labels: []);
    final a = await store.addFolder('A');
    await store.finishCollection(
        name: 'P1',
        kind: 'label',
        folderId: a.id,
        editMode: 'design',
        labels: []);
    await store.addFolder('B', a.id);
  });

  tearDownAll(() async {
    AppPaths.clearForTest();
    await deleteTempDirResilient(dir);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
    await st.refreshCollections();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [Provider<SyncController?>.value(value: null)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 700,
              child: LeftPanel(st: st, onNewProject: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('根目录：只显示根层内容，不平铺 A 内部', (tester) async {
    await mount(tester);
    expect(find.text('A'), findsOneWidget); // 文件夹行
    expect(find.text('P2'), findsOneWidget);
    expect(find.text('B'), findsNothing, reason: 'B 在 A 内，不应平铺出来');
    expect(find.text('P1'), findsNothing);
    expect(find.text('..'), findsNothing, reason: '根目录没有返回上级');
  });

  testWidgets('钻入 A：显示 B 与 P1，「..」出现，面包屑带 A', (tester) async {
    await mount(tester);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    expect(find.text('B'), findsOneWidget);
    expect(find.text('P1'), findsOneWidget);
    expect(find.text('P2'), findsNothing, reason: '进入 A 后根层工程不再显示');
    expect(find.text('..'), findsOneWidget);
    // 「A」只出现在面包屑里（当前层不再列出 A 自己）。
    expect(find.text('A'), findsOneWidget);
    expect(st.folderId, st.folders.firstWhere((f) => f.name == 'A').id,
        reason: '钻入后同步 folderId（保存对话框默认落这层）');
  });

  testWidgets('「..」返回上级；面包屑点「收藏夹」直接回根', (tester) async {
    await mount(tester);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('..'));
    await tester.pumpAndSettle();
    expect(find.text('P2'), findsOneWidget);
    expect(find.text('B'), findsNothing);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    // 页面上有两处「收藏夹」（面板标题 + 面包屑根），点面包屑那处（.last）。
    await tester.tap(find.text('收藏夹').last);
    await tester.pumpAndSettle();
    expect(find.text('P2'), findsOneWidget, reason: '面包屑回根后显示根层');
    expect(st.folderId, '');
  });

  testWidgets('搜索跨全库：在 A 层搜 P2 也能命中根目录工程', (tester) async {
    await mount(tester);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'P2');
    await tester.pumpAndSettle();
    // 两处命中：搜索框内容 + 结果行（功能正确性的证明就是结果行存在）。
    expect(find.text('P2'), findsNWidgets(2), reason: '搜索不受当前层限制');
  });
}
