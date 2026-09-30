import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/fav_node.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';

/// Phase 1：收藏树统一模型 + 控制器。
///
/// 约束：磁盘格式零改动（folders.json / index.json / `collection_<cid>.json`
/// 原样）；树真相源走 store.loadCollection，绝不依赖 AppState.overlayLabels。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;
  late LabelStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_favtree');
    LabelStore.instance.setBaseDirForTest(tmp);
    SharedPreferences.setMockInitialValues({});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
    store = st.store;
    await st.refreshCollections();
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<FavTreeController> makeController() async {
    final c = FavTreeController(st);
    await c.ready;
    return c;
  }

  MapLabel mk(String name,
          {String gid = '', double lat = 31.0, double lon = 121.0}) =>
      MapLabel(
          typeId: 'concrete',
          lat: lat,
          lon: lon,
          name: name,
          lineGroupId: gid);

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

  test('树结构：folder→project→mark/chain；不依赖 overlayLabels', () async {
    final folder = await store.addFolder('测试分区');
    final cid = await mkProject('杆路A', folder.id, [
      mk('G001', gid: 'g1', lat: 31.0, lon: 121.0),
      mk('G002', gid: 'g1', lat: 31.001, lon: 121.001),
      mk('单点', lat: 31.002, lon: 121.002),
    ]);
    await st.refreshCollections();
    final c = await makeController();

    // overlayLabels 为空（眼睛没开），树照样有数据——审计问题 2。
    expect(st.overlayLabels, isEmpty);

    final rootFolders =
        c.roots.where((n) => n.kind == FavKind.folder).toList();
    expect(rootFolders.map((n) => n.name), contains('测试分区'));

    final fkids = await c.childrenOf(folder.id);
    expect(
        fkids.where((n) => n.kind == FavKind.project).map((n) => n.id),
        contains(cid));

    final pkids = await c.childrenOf(cid);
    expect(pkids.where((n) => n.kind == FavKind.chain).length, 1);
    expect(pkids.where((n) => n.kind == FavKind.mark).length, 1);

    final chain = pkids.firstWhere((n) => n.kind == FavKind.chain);
    expect((await c.childrenOf(chain.id)).length, 2);

    expect(c.find(cid)?.name, '杆路A');
    expect(
        c.pathOf(chain.id).map((n) => n.name).toList(),
        ['测试分区', '杆路A', chain.name]);
    expect(c.pathOf('nope'), isEmpty);
  });

  test('moveToFolder(project)：落盘到 index.json', () async {
    final f1 = await store.addFolder('F1');
    final f2 = await store.addFolder('F2');
    final cid =
        await mkProject('工程X', f1.id, [mk('M1')]);
    await st.refreshCollections();
    final c = await makeController();

    expect(await c.moveToFolder(c.find(cid)!, f2.id), isTrue);

    final items = await store.loadIndex();
    expect(items.firstWhere((m) => m.id == cid).folder, f2.id);
    expect(c.find(cid)!.pid, f2.id);
    // 移回根
    expect(await c.moveToFolder(c.find(cid)!, ''), isTrue);
    expect((await store.loadIndex()).firstWhere((m) => m.id == cid).folder,
        isEmpty);
  });

  test('moveToFolder(folder)：正常移动 + 成环被拒绝', () async {
    final fa = await store.addFolder('A');
    final fb = await store.addFolder('B', fa.id);
    await st.refreshCollections();
    final c = await makeController();

    // 成环：A 移入自己的子文件夹 B → 拒绝且不落盘
    expect(await c.moveToFolder(c.find(fa.id)!, fb.id), isFalse);
    expect(
        (await store.loadFolders())
            .firstWhere((f) => f.id == fa.id)
            .parentId,
        isEmpty);
    // 自己移入自己 → 拒绝
    expect(await c.moveToFolder(c.find(fa.id)!, fa.id), isFalse);

    // 正常：B 移到根
    expect(await c.moveToFolder(c.find(fb.id)!, ''), isTrue);
    expect(
        (await store.loadFolders())
            .firstWhere((f) => f.id == fb.id)
            .parentId,
        isEmpty);
    // B 的 pid 已更新，进了 roots
    expect(c.roots.map((n) => n.id), contains(fb.id));
  });

  test('moveToFolder(mark)：目标文件夹自动创建"标记"工程', () async {
    final f1 = await store.addFolder('源');
    final f2 = await store.addFolder('目标');
    final cid = await mkProject('源工程', f1.id, [mk('待搬点')]);
    await st.refreshCollections();
    final c = await makeController();

    final mkid =
        (await c.childrenOf(cid)).firstWhere((n) => n.kind == FavKind.mark);
    expect(await c.moveToFolder(mkid, f2.id), isTrue);

    // 源工程已无该点
    expect(await store.loadCollection(cid), isEmpty);
    // 目标文件夹下自动建出"标记"工程且含该点
    final idx = await store.loadIndex();
    final targets = idx
        .where((m) =>
            m.folder == f2.id && (m.kind == 'mark' || m.name == '标记'))
        .toList();
    expect(targets, hasLength(1));
    final tlabels = await store.loadCollection(targets.first.id);
    expect(tlabels.map((l) => l.name), contains('待搬点'));
    // 树上可查到（缓存已失效，走磁盘重载）
    final tkids = await c.childrenOf(targets.first.id);
    expect(
        tkids.any((n) => n.kind == FavKind.mark && n.name == '待搬点'), isTrue);
  });

  test('moveToFolder(chain)：整条链的点一起搬走', () async {
    final f1 = await store.addFolder('源');
    final f2 = await store.addFolder('目标');
    final cid = await mkProject('链工程', f1.id, [
      mk('C1', gid: 'g9'),
      mk('C2', gid: 'g9'),
      mk('散点'),
    ]);
    await st.refreshCollections();
    final c = await makeController();

    final chain =
        (await c.childrenOf(cid)).firstWhere((n) => n.kind == FavKind.chain);
    expect(await c.moveToFolder(chain, f2.id), isTrue);

    // 源工程只剩散点
    final left = await store.loadCollection(cid);
    expect(left.map((l) => l.name).toList(), ['散点']);
    // 目标"标记"工程收到链上两点（lineGroupId 保留，链不断）
    final idx = await store.loadIndex();
    final target = idx
        .where((m) =>
            m.folder == f2.id && (m.kind == 'mark' || m.name == '标记'))
        .single;
    final tlabels = await store.loadCollection(target.id);
    expect(tlabels.map((l) => l.name).toSet(), {'C1', 'C2'});
    expect(tlabels.every((l) => l.lineGroupId == 'g9'), isTrue);
  });

  test('moveMarkToProject：跨工程移动标记', () async {
    final c1 = await mkProject('工程1', '', [mk('P1')]);
    final c2 = await mkProject('工程2', '', [mk('P2')]);
    await st.refreshCollections();
    final c = await makeController();

    final labelId = (await store.loadCollection(c1)).first.id;
    expect(await c.moveMarkToProject(labelId, c1, c2), isTrue);
    expect((await store.loadCollection(c1)).map((l) => l.name),
        isNot(contains('P1')));
    final dst = await store.loadCollection(c2);
    expect(dst.map((l) => l.name), contains('P1'));
    // 目标工程元数据保留（名称/类型/文件夹不被覆盖）
    final meta = (await store.loadIndex()).firstWhere((m) => m.id == c2);
    expect(meta.name, '工程2');

    // 同工程 / 目标不存在 → 拒绝
    expect(await c.moveMarkToProject(labelId, c2, c2), isFalse);
    expect(await c.moveMarkToProject('nope', c2, c1), isFalse);
  });

  test('mergeProject：合并工程并删除源', () async {
    final c1 = await mkProject('源工程', '', [mk('A1'), mk('A2')]);
    final c2 = await mkProject('目标工程', '', [mk('B1')]);
    await st.refreshCollections();
    final c = await makeController();

    expect(await c.mergeProject(c1, c2), 2);
    final idx = await store.loadIndex();
    expect(idx.any((m) => m.id == c1), isFalse);
    expect((await store.loadCollection(c2)).length, 3);
    // 树上源工程消失
    expect(c.find(c1), isNull);
    // 自合并 → 0
    expect(await c.mergeProject(c2, c2), 0);
  });

  test('countOf：含子孙文件夹的工程数 + 点数（审计问题 10）', () async {
    final fa = await store.addFolder('A');
    final fb = await store.addFolder('B', fa.id);
    await mkProject('P1', fa.id, [mk('a1', gid: 'g'), mk('a2', gid: 'g')]);
    await mkProject('P2', fb.id, [mk('b1')]);
    await st.refreshCollections();
    final c = await makeController();

    // A：P1(1工程+2点) + B：P2(1工程+1点) = 2工程 + 3点 = 5
    expect(await c.countOf(fa.id), 5);
    expect(await c.countOf(fb.id), 2);
    expect(await c.countOf(''), 5); // 根：两工程都在 A 子树下
  });

  test('可见性：hiddenIds 内存 + index.json visible 纯加法落盘', () async {
    final cid = await mkProject('工程V', '', []);
    await st.refreshCollections();
    final c = await makeController();

    expect(c.isVisible(cid), isTrue);
    await c.setVisible(cid, false);
    expect(c.isVisible(cid), isFalse);

    Future<Map<String, dynamic>> readEntry() async {
      final dir = await store.labelsDir();
      final raw = await File('${dir.path}/index.json').readAsString();
      final items = (jsonDecode(raw) as Map)['items'] as List;
      return (items.firstWhere((e) => e['id'] == cid) as Map)
          .cast<String, dynamic>();
    }

    expect((await readEntry())['visible'], isFalse);
    // 其它键原样保留（纯加法）
    expect((await readEntry())['name'], '工程V');

    // 新控制器读回：缺省 true，false 恢复
    final c2 = await makeController();
    expect(c2.isVisible(cid), isFalse);

    await c2.setVisible(cid, true);
    expect(c2.isVisible(cid), isTrue);
    expect((await readEntry()).containsKey('visible'), isFalse);
  });

  test('treeSelectedFolderId 独立于 AppState.folderId（审计问题 9）', () async {
    final c = await makeController();
    c.selectTreeFolder('some-folder');
    expect(c.treeSelectedFolderId, 'some-folder');
    expect(st.folderId, isEmpty); // 草稿保存目标层未被触碰
    c.selectTreeFolder('');
    expect(c.treeSelectedFolderId, isEmpty);
  });

  test('多选：toggle / selectOnly / selectAll / clear', () async {
    final c = await makeController();
    var notified = 0;
    c.addListener(() => notified++);

    c.toggleSelect('a');
    c.toggleSelect('b');
    expect(c.selected, {'a', 'b'});
    c.toggleSelect('a');
    expect(c.selected, {'b'});
    c.selectOnly('z');
    expect(c.selected, {'z'});
    c.selectAll(['x', 'y']);
    expect(c.selected, {'z', 'x', 'y'});
    c.clearSelection();
    expect(c.selected, isEmpty);
    expect(notified, greaterThan(0));
  });

  test('AppState 变更 → 控制器自动重建树', () async {
    final c = await makeController();
    expect(c.roots, isEmpty);
    await store.addFolder('后建的');
    await st.refreshCollections(); // 触发 AppState.notify
    // 控制器监听到并重建
    expect(c.roots.map((n) => n.name), contains('后建的'));
  });
}
