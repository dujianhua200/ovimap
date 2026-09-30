import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/fav_node.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';
import 'package:ovimap/ui/favorites/trash.dart';

/// TrashStore 进出回收站 round-trip（临时目录，磁盘格式零改动断言）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;
  late LabelStore store;
  late FavTreeController c;
  late TrashStore trash;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_trash');
    LabelStore.instance.setBaseDirForTest(tmp);
    SharedPreferences.setMockInitialValues({});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
    store = st.store;
    await st.refreshCollections();
    c = FavTreeController(st);
    await c.ready;
    trash = TrashStore(onChanged: () => st.refreshCollections());
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

  Future<Directory> labelsDir() => store.labelsDir();

  test('工程进出回收站 round-trip：文件删除/还原，trash.json 为唯一新增文件', () async {
    final cid = await mkProject('杆路A', '', [mk('G001'), mk('G002')]);
    await st.refreshCollections();
    await c.ready;

    final node = c.find(cid);
    expect(node, isNotNull);
    expect(node!.kind, FavKind.project);

    final dir = await labelsDir();
    final before =
        dir.listSync().map((e) => e.path.split('/').last).toSet();

    await trash.trashNode(c, node);

    // 工程文件 + 索引条目消失。
    expect(File('${dir.path}/collection_$cid.json').existsSync(), isFalse);
    expect((await store.loadIndex()).where((m) => m.id == cid), isEmpty);
    expect(trash.items, hasLength(1));
    expect(trash.items.first.kind, 'project');
    expect(trash.items.first.name, '杆路A');

    // trash.json 是唯一新增文件（磁盘格式零改动）。
    final after =
        dir.listSync().map((e) => e.path.split('/').last).toSet();
    expect(after.difference(before), {'trash.json'});

    // payload 里有 meta + labels。
    final payload =
        jsonDecode(trash.items.first.payloadJson) as Map<String, dynamic>;
    expect((payload['meta'] as Map)['name'], '杆路A');
    expect((payload['labels'] as List), hasLength(2));

    // 还原。
    await trash.restore(trash.items.first.trashId);
    expect(trash.items, isEmpty);
    final metas = await store.loadIndex();
    expect(metas.where((m) => m.id == cid), hasLength(1));
    expect(metas.firstWhere((m) => m.id == cid).name, '杆路A');
    final labels = await store.loadCollection(cid);
    expect(labels.map((l) => l.name), containsAll(['G001', 'G002']));
  });

  test('文件夹进回收站：整棵子树（子文件夹+多工程）删除并还原', () async {
    final f1 = await store.addFolder('分区1');
    final f2 = await store.addFolder('子分区', f1.id);
    final cid1 = await mkProject('工程1', f1.id, [mk('A')]);
    final cid2 = await mkProject('工程2', f2.id, [mk('B'), mk('C')]);
    await st.refreshCollections();
    // 新 controller：拿到最新骨架。
    c.dispose();
    c = FavTreeController(st);
    await c.ready;

    final node = c.find(f1.id);
    expect(node, isNotNull);

    await trash.trashNode(c, node!);

    expect((await store.loadFolders()).where((f) => f.id == f1.id), isEmpty);
    expect((await store.loadFolders()).where((f) => f.id == f2.id), isEmpty);
    final dir = await labelsDir();
    expect(File('${dir.path}/collection_$cid1.json').existsSync(), isFalse);
    expect(File('${dir.path}/collection_$cid2.json').existsSync(), isFalse);
    expect(trash.items, hasLength(1));
    expect(trash.items.first.kind, 'folder');

    await trash.restore(trash.items.first.trashId);

    final folders = await store.loadFolders();
    expect(folders.where((f) => f.id == f1.id), hasLength(1));
    final restoredF2 = folders.where((f) => f.id == f2.id);
    expect(restoredF2, hasLength(1));
    expect(restoredF2.first.parentId, f1.id); // 父子关系保留
    final metas = await store.loadIndex();
    expect(metas.where((m) => m.id == cid1).first.folder, f1.id);
    expect(metas.where((m) => m.id == cid2).first.folder, f2.id);
    expect((await store.loadCollection(cid2)).map((l) => l.name),
        containsAll(['B', 'C']));
  });

  test('还原时原文件夹不存在则回根', () async {
    final cid = await mkProject('孤儿工程', 'ghost-folder', [mk('X')]);
    await st.refreshCollections();
    c.dispose();
    c = FavTreeController(st);
    await c.ready;

    final node = c.find(cid)!;
    await trash.trashNode(c, node);
    await trash.restore(trash.items.first.trashId);

    final metas = await store.loadIndex();
    final restored = metas.firstWhere((m) => m.id == cid);
    expect(restored.folder, isEmpty); // 回根
    expect(await store.loadCollection(cid), hasLength(1));
  });

  test('彻底删除与清空回收站', () async {
    final cid1 = await mkProject('E1', '', [mk('A')]);
    final cid2 = await mkProject('E2', '', [mk('B')]);
    await st.refreshCollections();
    c.dispose();
    c = FavTreeController(st);
    await c.ready;

    await trash.trashNode(c, c.find(cid1)!);
    await trash.trashNode(c, c.find(cid2)!);
    expect(trash.items, hasLength(2));

    await trash.deleteForever(trash.items.first.trashId);
    expect(trash.items, hasLength(1));

    await trash.emptyTrash();
    expect(trash.items, isEmpty);

    // trash.json 落盘为空数组。
    final dir = await labelsDir();
    final raw = await File('${dir.path}/trash.json').readAsString();
    expect(jsonDecode(raw), isEmpty);
  });

  test('trashNode 拒绝 mark/chain 等虚拟节点', () async {
    final cid = await mkProject('P', '', [mk('G1', gid: 'g'), mk('G2', gid: 'g')]);
    await st.refreshCollections();
    c.dispose();
    c = FavTreeController(st);
    await c.ready;
    final kids = await c.childrenOf(cid);
    expect(kids, isNotEmpty);
    final mark = kids.firstWhere((k) => k.kind == FavKind.mark,
        orElse: () => kids.first);
    expect(() => trash.trashNode(c, mark), throwsArgumentError);
  });

  test('D1：30 天过期——load() 丢弃超期条目并把裁剪写回 trash.json', () async {
    final dir = await labelsDir();
    final f = File('${dir.path}/trash.json');
    TrashItem item(String tid, String name, DateTime at) => TrashItem(
        trashId: tid,
        kind: 'project',
        name: name,
        payloadJson: '{}',
        deletedAt: at);
    final now = DateTime.now();
    await f.writeAsString(jsonEncode([
      item('t-old', '旧工程', now.subtract(const Duration(days: 31))).toJson(),
      item('t-edge', '恰好30天', now.subtract(const Duration(days: 30))).toJson(),
      item('t-new', '新工程', now).toJson(),
    ]));

    await trash.load();

    // 超 30 天的被丢弃；恰好 30 天（inDays == 30）保留。
    expect(trash.items.map((e) => e.trashId), ['t-new', 't-edge']);
    // 裁剪后的列表写回了磁盘。
    final back = (jsonDecode(await f.readAsString()) as List)
        .map((e) => (e as Map)['trashId'])
        .toList();
    expect(back, ['t-new', 't-edge']);
  });

  test('D1：未过期时 load() 不重写 trash.json（mtime 不变）', () async {
    final dir = await labelsDir();
    final f = File('${dir.path}/trash.json');
    final now = DateTime.now();
    await f.writeAsString(jsonEncode([
      TrashItem(
              trashId: 't-new',
              kind: 'project',
              name: '新工程',
              payloadJson: '{}',
              deletedAt: now)
          .toJson(),
    ]));
    final mtime = f.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await trash.load();
    expect(trash.items, hasLength(1));
    expect(f.lastModifiedSync(), mtime);
  });
}
