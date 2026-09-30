import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/fav_node.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';
import 'package:ovimap/state/undo_stack.dart';
import 'package:ovimap/ui/favorites/trash.dart';

/// W1：全局撤销/重做核心。
///
/// 普通 `test()`（非 testWidgets）+ 临时目录真实磁盘 IO，
/// 沿用 fav_trash_test.dart 的注入模式。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;
  late LabelStore store;
  late FavTreeController c;
  late TrashStore trash;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_undo');
    LabelStore.instance.setBaseDirForTest(tmp);
    SharedPreferences.setMockInitialValues({});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
    store = st.store;
    await st.refreshCollections();
    c = FavTreeController(st);
    await c.ready;
    trash = TrashStore(
        onChanged: () => st.refreshCollections(), appState: st);
    await trash.load();
  });

  tearDown(() async {
    c.dispose();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  MapLabel mk(String name, {String gid = ''}) => MapLabel(
      typeId: 'concrete', lat: 31.0, lon: 121.0, name: name, lineGroupId: gid);

  Future<String> mkProject(String name, String folderId, List<MapLabel> labels,
      {String kind = 'label'}) {
    return store.finishCollection(
      name: name,
      kind: kind,
      folderId: folderId,
      editMode: 'design',
      labels: labels,
      clearDraftNow: false,
    );
  }

  Future<String> folderOf(String cid) async =>
      (await store.loadFolders())
          .firstWhere((f) => f.id == cid)
          .parentId;

  group('UndoStack 基础', () {
    test('上限 50：压 55 条剩 50，最早的被丢弃', () async {
      final gs = UndoStack();
      for (var i = 0; i < 55; i++) {
        expect(await gs.execute('op$i', () async => true, () async => true),
            isTrue);
      }
      expect(gs.undoCount, 50);
      expect(gs.lastUndoDescription, 'op54');
      // 50 次 undo 后栈空（op0..op4 已被丢弃）。
      for (var i = 0; i < 50; i++) {
        expect(await gs.undo(), isTrue);
      }
      expect(gs.canUndo, isFalse);
      expect(await gs.undo(), isFalse);
    });

    test('新动作清空 redo 栈', () async {
      final gs = UndoStack();
      await gs.execute('a', () async => true, () async => true);
      await gs.undo();
      expect(gs.canRedo, isTrue);
      await gs.execute('b', () async => true, () async => true);
      expect(gs.canRedo, isFalse);
      expect(gs.redoCount, 0);
    });

    test('doIt 抛异常不压栈', () async {
      final gs = UndoStack();
      await expectLater(
          gs.execute('boom', () async {
            throw StateError('x');
          }, () async => true),
          throwsStateError);
      expect(gs.canUndo, isFalse);
      expect(gs.undoCount, 0);
    });

    test('doIt 返回 false 不压栈、不清空 redo', () async {
      final gs = UndoStack();
      await gs.execute('a', () async => true, () async => true);
      await gs.undo();
      expect(gs.canRedo, isTrue);
      expect(await gs.execute('noop', () async => false, () async => true),
          isFalse);
      expect(gs.undoCount, 0);
      expect(gs.canRedo, isTrue); // redo 栈不受影响
    });

    test('suspend 防重入：undo/redo 期间内层 execute 只执行不记录', () async {
      final gs = UndoStack();
      var innerRuns = 0;
      await gs.execute(
          'outer',
          () async {
            await gs.execute('inner', () async {
              innerRuns++;
              return true;
            }, () async => true);
            return true;
          },
          () async => true);
      expect(innerRuns, 1);
      expect(gs.undoCount, 1); // 内层未被记录
      expect(gs.lastUndoDescription, 'outer');
    });

    test('undo 失败（返回 false）不进 redo 栈、不抛错', () async {
      final gs = UndoStack();
      await gs.execute('a', () async => true, () async => false);
      expect(await gs.undo(), isFalse);
      expect(gs.canUndo, isFalse);
      expect(gs.canRedo, isFalse);
    });

    test('时间戳二选一逻辑（纯逻辑）', () {
      final t0 = DateTime(2026, 1, 1);
      final t1 = t0.add(const Duration(seconds: 1));
      // 全局栈空 → 走草稿
      expect(
          shouldUseGlobalUndo(
              canUndo: false, lastChangeAt: t1, lastDraftPushAt: t0),
          isFalse);
      // 全局更新但不晚于草稿（相等也不行，严格大于）→ 走草稿
      expect(
          shouldUseGlobalUndo(
              canUndo: true, lastChangeAt: t0, lastDraftPushAt: t0),
          isFalse);
      expect(
          shouldUseGlobalUndo(
              canUndo: true, lastChangeAt: t0, lastDraftPushAt: t1),
          isFalse);
      // 全局更新且晚于草稿 → 走全局
      expect(
          shouldUseGlobalUndo(
              canUndo: true, lastChangeAt: t1, lastDraftPushAt: t0),
          isTrue);
    });

    test('lastChangeAt：execute/undo/redo 成功时更新', () async {
      final gs = UndoStack();
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      expect(gs.lastChangeAt, epoch);
      await gs.execute('a', () async => true, () async => true);
      final t1 = gs.lastChangeAt;
      expect(t1.isAfter(epoch), isTrue);
      await gs.undo();
      expect(gs.lastChangeAt.isAfter(t1) || gs.lastChangeAt == t1, isTrue);
      await gs.redo();
      expect(gs.lastChangeAt.isAfter(epoch), isTrue);
    });
  });

  group('收藏树操作 undo/redo', () {
    test('文件夹重命名 undo+redo', () async {
      final f = await store.addFolder('旧名');
      await st.refreshCollections();

      expect(await c.renameFolderUndoable(f.id, '新名'), isTrue);
      expect((await store.loadFolders())
          .firstWhere((e) => e.id == f.id)
          .name, '新名');

      expect(await st.undoStack.undo(), isTrue);
      expect((await store.loadFolders())
          .firstWhere((e) => e.id == f.id)
          .name, '旧名');

      expect(await st.undoStack.redo(), isTrue);
      expect((await store.loadFolders())
          .firstWhere((e) => e.id == f.id)
          .name, '新名');
    });

    test('工程重命名 undo', () async {
      final cid = await mkProject('旧工程名', '', [mk('G1')]);
      await st.refreshCollections();

      expect(await c.renameCollectionUndoable(cid, '新工程名'), isTrue);
      expect(st.collections.firstWhere((m) => m.id == cid).name, '新工程名');

      await st.undoStack.undo();
      expect(st.collections.firstWhere((m) => m.id == cid).name, '旧工程名');
    });

    test('新建文件夹 undo（删掉新建的文件夹）', () async {
      final newId = await c.addFolderUndoable('临时文件夹');
      expect(newId, isNotNull);
      final fid = newId as String;
      expect(c.find(fid), isNotNull);

      await st.undoStack.undo();
      expect(c.find(fid), isNull);
    });

    test('工程改样式 undo', () async {
      final cid = await mkProject('工程', '', [mk('G1')]);
      await st.refreshCollections();

      expect(await c.setCollectionStyleUndoable(cid, 0xFFFF0000, 5.0), isTrue);
      var meta = st.collections.firstWhere((m) => m.id == cid);
      expect(meta.color, 0xFFFF0000);
      expect(meta.width, 5.0);

      await st.undoStack.undo();
      meta = st.collections.firstWhere((m) => m.id == cid);
      expect(meta.color, 0);
      expect(meta.width, 0);
    });

    test('文件夹移动 undo+redo', () async {
      final fa = await store.addFolder('A');
      final fb = await store.addFolder('B');
      final child = await store.addFolder('Child', fa.id);
      await st.refreshCollections();

      final node = c.find(child.id)!;
      expect(node.kind, FavKind.folder);
      expect(await c.moveToFolder(node, fb.id), isTrue);
      expect(c.find(child.id)!.pid, fb.id);

      expect(await st.undoStack.undo(), isTrue);
      expect(c.find(child.id)!.pid, fa.id);

      expect(await st.undoStack.redo(), isTrue);
      expect(c.find(child.id)!.pid, fb.id);
    });

    test('工程移动 undo', () async {
      final fa = await store.addFolder('A');
      final fb = await store.addFolder('B');
      final cid = await mkProject('工程', fa.id, [mk('P1')]);
      await st.refreshCollections();

      final node = c.find(cid)!;
      expect(await c.moveToFolder(node, fb.id), isTrue);
      expect(c.find(cid)!.pid, fb.id);

      await st.undoStack.undo();
      expect(c.find(cid)!.pid, fa.id);
    });

    test('标记跨工程移动 undo', () async {
      final from = await mkProject('源', '', [mk('M1')]);
      final to = await mkProject('目标', '', [mk('T1')]);
      await st.refreshCollections();

      final lid = (await c.labelsOf(from)).first.id;
      expect(await c.moveMarkToProject(lid, from, to), isTrue);
      expect((await c.labelsOf(from)).map((e) => e.id), isNot(contains(lid)));
      expect((await c.labelsOf(to)).map((e) => e.id), contains(lid));

      expect(await st.undoStack.undo(), isTrue);
      expect((await c.labelsOf(from)).map((e) => e.id), contains(lid));
      expect((await c.labelsOf(to)).map((e) => e.id), isNot(contains(lid)));
    });

    test('标记移入文件夹的 undo（目标"标记"工程自动解析）', () async {
      final from = await mkProject('源', '', [mk('M1')]);
      final folder = await store.addFolder('目标层');
      await st.refreshCollections();

      final markNode =
          (await c.childrenOf(from)).firstWhere((n) => n.isMark);
      expect(await c.moveToFolder(markNode, folder.id), isTrue);
      // 目标文件夹下自动建了 kind=='mark' 的工程，点已搬入
      final markProjs = st.collections
          .where((m) => m.kind == 'mark' && m.folder == folder.id)
          .toList();
      expect(markProjs, hasLength(1));
      expect((await c.labelsOf(from)), isEmpty);

      expect(await st.undoStack.undo(), isTrue);
      expect((await c.labelsOf(from)).map((e) => e.name), contains('M1'));
    });

    test('mergeProject 的 undo+redo', () async {
      final from = await mkProject('源', '', [mk('F1'), mk('F2')]);
      final to = await mkProject('目标', '', [mk('T1')]);
      await st.refreshCollections();

      final moved = await c.mergeProject(from, to);
      expect(moved, 2);
      expect((await c.labelsOf(to)).length, 3);
      expect(c.find(from), isNull);

      expect(await st.undoStack.undo(), isTrue);
      expect(c.find(from), isNotNull);
      expect((await c.labelsOf(from)).length, 2);
      expect((await c.labelsOf(to)).length, 1);

      expect(await st.undoStack.redo(), isTrue);
      expect((await c.labelsOf(to)).length, 3);
      expect(c.find(from), isNull);
    });
  });

  group('回收站 undo/redo', () {
    test('工程 trash→restore 的 undo/redo 闭环', () async {
      final cid = await mkProject('待删', '', [mk('G1'), mk('G2')]);
      await st.refreshCollections();
      final node = c.find(cid)!;

      final trashId = await trash.trashNode(c, node);
      expect(trashId, isNotEmpty);
      expect(c.find(cid), isNull);
      expect(trash.items, hasLength(1));

      // undo trashNode = 还原
      expect(await st.undoStack.undo(), isTrue);
      expect(c.find(cid), isNotNull);
      expect((await c.labelsOf(cid)).length, 2);
      expect(trash.items, isEmpty);

      // redo = 根据 nodeId 重新 trash
      expect(await st.undoStack.redo(), isTrue);
      expect(c.find(cid), isNull);
      expect(trash.items, hasLength(1));
    });

    test('文件夹 trash 的 undo：子树整体还原', () async {
      final f = await store.addFolder('父');
      final sub = await store.addFolder('子', f.id);
      final cid = await mkProject('工程', sub.id, [mk('G1')]);
      await st.refreshCollections();

      await trash.trashNode(c, c.find(f.id)!);
      expect(c.find(f.id), isNull);
      expect(c.find(cid), isNull);

      expect(await st.undoStack.undo(), isTrue);
      expect(c.find(f.id), isNotNull);
      expect(c.find(sub.id), isNotNull);
      expect(c.find(cid), isNotNull);
      expect((await c.labelsOf(cid)).length, 1);
      // 父子关系保持
      expect((await folderOf(sub.id)), f.id);
    });

    test('deleteForever 的 undo：TrashItem 写回', () async {
      final cid = await mkProject('待删', '', [mk('G1')]);
      await st.refreshCollections();

      final trashId = await trash.trashNode(c, c.find(cid)!);
      await trash.deleteForever(trashId);
      expect(trash.items, isEmpty);

      // 撤销 deleteForever → 条目写回
      expect(await st.undoStack.undo(), isTrue);
      expect(trash.items, hasLength(1));

      // 再撤销一次 → 撤销 trashNode → 工程还原
      expect(await st.undoStack.undo(), isTrue);
      expect(c.find(cid), isNotNull);
      expect(trash.items, isEmpty);
    });

    test('emptyTrash 的 undo：全部条目写回', () async {
      final cid1 = await mkProject('A', '', [mk('G1')]);
      final cid2 = await mkProject('B', '', [mk('G2')]);
      await st.refreshCollections();
      await trash.trashNode(c, c.find(cid1)!);
      await trash.trashNode(c, c.find(cid2)!);
      expect(trash.items, hasLength(2));

      await trash.emptyTrash();
      expect(trash.items, isEmpty);

      expect(await st.undoStack.undo(), isTrue);
      expect(trash.items, hasLength(2));
    });
  });

  group('标记编辑 undo（AppState.update/removeOverlayLabel）', () {
    test('removeOverlayLabel 的 undo：删点后插回原位', () async {
      final cid = await mkProject('工程', '', [mk('A'), mk('B'), mk('C')]);
      await st.refreshCollections();
      st.overlayLabels[cid] = await store.loadCollection(cid);

      final target = st.overlayLabels[cid]![1];
      await st.removeOverlayLabel(cid, target);
      expect(st.overlayLabels[cid]!.length, 2);

      expect(await st.undoStack.undo(), isTrue);
      final restored = st.overlayLabels[cid]!;
      expect(restored.length, 3);
      expect(restored[1].id, target.id);

      expect(await st.undoStack.redo(), isTrue);
      expect(st.overlayLabels[cid]!.length, 2);
    });

    test('updateOverlayLabel 的 undo：恢复旧属性', () async {
      final cid = await mkProject('工程', '', [mk('A')]);
      await st.refreshCollections();
      st.overlayLabels[cid] = await store.loadCollection(cid);

      final orig = st.overlayLabels[cid]!.first;
      final edited = MapLabel.fromJson(
          Map<String, dynamic>.from(orig.toJson()))
        ..name = '改名';
      await st.updateOverlayLabel(cid, edited);
      expect(st.overlayLabels[cid]!.first.name, '改名');

      expect(await st.undoStack.undo(), isTrue);
      expect(st.overlayLabels[cid]!.first.name, 'A');
    });
  });
}
