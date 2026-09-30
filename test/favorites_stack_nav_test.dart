// 收藏夹树护栏（Phase 2：桌面左栏树体换共享 FavTree；整树平铺、+/− 折叠、
// [n] 计数、搜索跨全库；树选中层走 FavTreeController.treeSelectedFolderId）。
//
// 数据：根工程 P2；文件夹 A（内含工程 P1 与子文件夹 B）。
// 真实文件 I/O 用 `tester.runAsync`；选层/折叠是纯 setState。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';
import 'package:ovimap/sync/sync_controller.dart';
import 'package:ovimap/ui/desktop/left_panel.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fs_cleanup.dart';

final store = LabelStore.instance;

/// 当前挂载面板使用的树控制器（断言树选中层用）。
FavTreeController? testCtrl;

Future<void> mountPanel(WidgetTester tester, AppState st,
    {void Function(MapLabel)? onLocate}) async {
  // ⚠️ testWidgets body 是假时钟区：控制器构造里的真实 IO（_init/_loadVisibility）
  // 若直接 await 会永久挂起，必须在 runAsync 里做；同时预热点位缓存——
  // FavTree 的 FutureBuilder 在假时钟区里读盘也会挂起，缓存命中则走 microtask
  // 可正常完成（countOf/childrenOf/search 全走 _labelsOf 缓存）。
  await tester.runAsync(() async {
    testCtrl = FavTreeController(st);
    await testCtrl!.ready;
    for (final p in testCtrl!.projects) {
      await testCtrl!.labelsOf(p.id);
    }
  });
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<SyncController?>.value(value: null),
        // 共享收藏组件经 Provider 取 AppState（显隐联动等）；
        // AppState 是 ChangeNotifier，必须用 ChangeNotifierProvider。
        ChangeNotifierProvider<AppState>.value(value: st),
        ChangeNotifierProvider<FavTreeController>.value(value: testCtrl!),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 700,
            child: LeftPanel(st: st, onNewProject: () {}, onLocate: onLocate),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;
  late AppState st;
  late String aid; // 文件夹 A 的 id

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ovimap_fav_tree');
    store.setBaseDirForTest(dir);
    await store.finishCollection(
        name: 'P2', kind: 'label', folderId: '', editMode: 'design', labels: []);
    final a = await store.addFolder('A');
    aid = a.id;
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

  testWidgets('整树平铺（奥维式）：文件夹与工程同树可见，各带 [n] 计数', (tester) async {
    await mountPanel(tester, st);
    expect(find.text('收藏夹'), findsWidgets); // 面板标题 + 树根行
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget, reason: '默认全展开，B 随 A 平铺可见');
    // v3.9：工程也在树里（用户口径：所有东西都在收藏夹树下看得见）。
    expect(find.text('P2'), findsOneWidget, reason: '根目录工程在树里');
    expect(find.text('P1'), findsOneWidget, reason: 'A 里的工程也在树里');
    expect(find.text('[1]'), findsWidgets, reason: 'A[1]');
    expect(find.text('[2]'), findsOneWidget, reason: '根行收藏夹[2 个工程]');
  });

  testWidgets('点 A 行：选中该层（Phase 2：树选中走 treeSelectedFolderId，树保持全量可见）',
      (tester) async {
    await mountPanel(tester, st);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(testCtrl!.treeSelectedFolderId, aid, reason: '树选中层走控制器');
    expect(find.text('P2'), findsOneWidget, reason: '树是全量视图，不因选层而隐藏');
  });

  testWidgets('点 A 的 −：B 收起；点 +：B 再展开', (tester) async {
    await mountPanel(tester, st);
    // 根行无 +/−；A / B / P1 / P2 行有（空文件夹/空工程也显示）。
    // 树顺序 根, A, B, P1, P2 ⇒ at(0) 是 A 的。
    expect(find.byIcon(Icons.remove), findsNWidgets(4));
    await tester.tap(find.byIcon(Icons.remove).at(0));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsNothing, reason: '收起后 B 隐藏');
    expect(find.text('P1'), findsNothing, reason: '收起后 P1 隐藏');
    expect(find.text('A'), findsOneWidget, reason: 'A 行本身保留');
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget, reason: '再展开 B 回来');
  });

  testWidgets('标记收藏在树中列出点行：图钉+名字+备注，点击定位', (tester) async {
    // 建标记收藏（真实 IO 必须在 runAsync——testWidgets 是假时钟区）。
    final cid = await tester.runAsync(() async {
      final cid = await store.finishCollection(
          name: '标记', kind: 'mark', folderId: '', editMode: 'design', labels: []);
      final ls = await store.loadCollection(cid);
      ls.add(MapLabel(typeId: 'fiberbox', seq: 1, lat: 32.0, lon: 114.0,
          name: '标记1')..note = '光交');
      await store.saveCollectionLabels(cid, ls);
      st.visibleCids.add(cid);
      st.overlayLabels[cid] = ls;
      await st.refreshCollections();
      return cid;
    });

    await mountPanel(tester, st);
    expect(find.text('标记1'), findsOneWidget, reason: '树中列出标记点行');
    expect(find.text('光交'), findsOneWidget, reason: '备注灰字跟显');

    // 点击点行 → 定位回调（属性对话框链路由右键菜单既有用例覆盖）。
    var located = <MapLabel>[];
    await mountPanel(tester, st, onLocate: (l) => located.add(l));
    await tester.tap(find.text('标记1'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(located.length, 1, reason: '瞬间定位');
    // 用户指定：点击标记**不弹属性框**（属性走右键）。
    expect(find.text('标签名称'), findsNothing, reason: '左键点击不应弹窗');
    expect(cid, isNotEmpty);
  });

  testWidgets('搜索跨全库：在 A 选中态搜 P2 也能命中根目录工程', (tester) async {
    await mountPanel(tester, st);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'P2');
    await tester.pumpAndSettle();
    // 两处 P2：搜索框内容 + 结果行。
    expect(find.text('P2'), findsNWidgets(2));
  });

  testWidgets('批量选择入口必须可见（用户反馈：只靠 Ctrl 找不到）', (tester) async {
    await mountPanel(tester, st);
    // 标题栏常驻：新建工程 / 新建文件夹 / 回收站。
    expect(find.byTooltip('新建工程'), findsOneWidget);
    expect(find.byTooltip('新建文件夹（建在当前选中层）'), findsOneWidget);
    expect(find.byTooltip('回收站'), findsOneWidget);

    // Ctrl+A 全选 → 底部多选操作条出现（共享 FavSelectBar）。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 '), findsOneWidget,
        reason: '操作条实时显示已选数');
    expect(find.byTooltip('全选'), findsOneWidget);
    expect(find.byTooltip('取消选择'), findsOneWidget);
    expect(find.byTooltip('移动到'), findsOneWidget);
    expect(find.byTooltip('改样式'), findsOneWidget);
    expect(find.byTooltip('删除（进回收站）'), findsOneWidget);

    // 取消选择 → 操作条收起。
    await tester.tap(find.byTooltip('取消选择'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 '), findsNothing);
  });
}
