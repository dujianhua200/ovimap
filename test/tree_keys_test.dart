import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';
import 'package:ovimap/ui/favorites/fav_actions.dart';
import 'package:ovimap/ui/favorites/tree_keys.dart';

/// W2：快捷键（F2/Ctrl+A）+ 批量删除收敛（单条撤销）+ 确认框文案。
///
/// - 普通 `test()`：deleteMarksBatch / selectAllTreeNodes（真实磁盘 IO，
///   沿用 undo_test.dart 的临时目录注入模式）；
/// - `testWidgets`：TreeKeyHandler 的 F2/Ctrl+A（假时钟区，控制器构造与
///   点位预热进 runAsync，见 favorites_full_regression_test.dart）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;
  late LabelStore store;
  late String fid; // 文件夹
  late String cid; // 标记工程（含 3 点）

  MapLabel mk(String name) =>
      MapLabel(typeId: 'concrete', lat: 31.0, lon: 121.0, name: name);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_treekeys');
    LabelStore.instance.setBaseDirForTest(tmp);
    SharedPreferences.setMockInitialValues({});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
    store = st.store;
    await st.refreshCollections();
    fid = (await store.addFolder('F')).id;
    cid = await store.finishCollection(
      name: '标记工程',
      kind: 'mark',
      folderId: '',
      editMode: 'design',
      labels: [mk('m1'), mk('m2'), mk('m3')],
      clearDraftNow: false,
    );
    await st.refreshCollections();
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('deleteMarksBatch（批量删除合并为一条撤销）', () {
    test('3 个标记 → 1 条撤销记录，undo 按原位还原', () async {
      final labels = await store.loadCollection(cid);
      st.overlayLabels[cid] = labels; // 模拟工程已打开
      final before = st.undoStack.undoCount;
      final res = await deleteMarksBatch(
          st, [(cid, labels[0]), (cid, labels[1]), (cid, labels[2])]);
      expect(res, (deleted: 3, skipped: 0));
      expect(st.undoStack.undoCount, before + 1,
          reason: 'N 个点只记一条（W1 遗留问题已修复）');
      expect(st.undoStack.lastUndoDescription, '删除 3 个标记');
      expect(st.overlayLabels[cid], isEmpty);

      expect(await st.undoStack.undo(), isTrue);
      final restored = st.overlayLabels[cid]!;
      expect(restored.map((e) => e.name).toList(), ['m1', 'm2', 'm3'],
          reason: 'undo 按原 index 降序插回，顺序还原');
    });

    test('所在工程未打开 → skipped 并给出计数（B2 失败说原因）', () async {
      final labels = await store.loadCollection(cid);
      // 不往 overlayLabels 放：模拟工程未打开。
      final before = st.undoStack.undoCount;
      final res = await deleteMarksBatch(st, [(cid, labels[0])]);
      expect(res, (deleted: 0, skipped: 1));
      expect(st.undoStack.undoCount, before, reason: '没删掉就不记栈');
    });
  });

  group('selectAllTreeNodes（Ctrl+A 口径）', () {
    test('选中 folders + projects + 已加载的子节点', () async {
      final c = FavTreeController(st);
      await c.ready;
      await c.childrenOf(cid); // 懒加载子节点进索引
      addTearDown(c.dispose);
      selectAllTreeNodes(c);
      expect(c.selected.length, c.allIndexedIds.length);
      expect(c.selected, contains(fid));
      expect(c.selected, contains(cid));
      // 子节点（mark）在索引里，也被选中。
      expect(
          c.allIndexedIds.any((id) => c.find(id)?.isMark == true), isTrue);
      expect(c.selected.any((id) => c.find(id)?.isMark == true), isTrue);
    });
  });

  group('TreeKeyHandler（widget）', () {
    late FavTreeController c;

    Future<void> mountKeys(WidgetTester tester) async {
      c = (await tester.runAsync(() async {
        final cc = FavTreeController(st);
        await cc.ready;
        for (final p in cc.projects) {
          await cc.labelsOf(p.id);
        }
        await cc.childrenOf(cid);
        return cc;
      }))!;
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: st),
          ChangeNotifierProvider<FavTreeController>.value(value: c),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TreeKeyHandler(
              controller: c,
              autofocus: true,
              child: const SizedBox(width: 300, height: 600),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      addTearDown(c.dispose);
    }

    Future<void> sendCtrlA(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();
    }

    testWidgets('Ctrl+A 全选索引全部节点', (tester) async {
      await mountKeys(tester);
      await sendCtrlA(tester);
      expect(c.selected.length, c.allIndexedIds.length);
      expect(c.selected, containsAll(c.allIndexedIds));
    });

    testWidgets('F2 未选 → 提示先选一项', (tester) async {
      await mountKeys(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('先选中一项（点击条目）'), findsOneWidget);
    });

    testWidgets('F2 多选 → 提示请只选中一项', (tester) async {
      await mountKeys(tester);
      c.selectAll([fid, cid]);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('请只选中一项'), findsOneWidget);
    });

    testWidgets('F2 选中单个文件夹 → 弹出重命名框', (tester) async {
      await mountKeys(tester);
      c.selectOnly(fid);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('重命名文件夹'), findsOneWidget);
      // 对话框出现即证明 F2 接通了重命名流程；不点取消——askText 的
      // controller 在退场动画期间 dispose 是既有实现的时序，
      // 本用例不断言它。
    });

    testWidgets('F2 选中标记 → 提示只能重命名文件夹或工程', (tester) async {
      await mountKeys(tester);
      final markId =
          c.allIndexedIds.firstWhere((id) => c.find(id)?.isMark == true);
      c.selectOnly(markId);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('只能重命名文件夹或工程'), findsOneWidget);
    });
  });
}
