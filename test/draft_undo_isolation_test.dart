// 撤销栈跨工程隔离护栏。
//
// 背景：快照栈只存点位 JSON，不带工程身份。以前的实现里切换文档
// （打开别的工程 / 新建工程 / 删除当前工程）不清栈，于是：
//   · 打开 B 后按 Ctrl+Z 会把 A 的点整批恢复进 B，并被自动保存写进 B 的文件；
//   · 新建工程后第一次撤销会把上一个工程"撤回来"。
// 这两条都是数据污染，外业现场很难察觉，事后核对杆号才会发现串了工程。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fs_cleanup.dart';

final store = LabelStore.instance;

List<MapLabel> labelsN(int n, {double lat = 32.0}) => [
  for (var i = 0; i < n; i++)
    MapLabel(typeId: 'pole', seq: i + 1, lat: lat + i * 0.001, lon: 114.0),
];

Future<AppState> makeState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final st = AppState();
  st.setPrefsForTest(await SharedPreferences.getInstance());
  return st;
}

Future<String> saveProject(String name, List<MapLabel> labels) =>
    store.finishCollection(
      name: name,
      kind: 'label',
      folderId: '',
      editMode: 'design',
      labels: labels,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_undo_isolation');
    store.setBaseDirForTest(dir);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    AppPaths.clearForTest();
    await deleteTempDirResilient(dir);
  });

  test('打开工程 B 后撤销，不会把工程 A 的点带进来', () async {
    final cidA = await saveProject('工程A', labelsN(3));
    final cidB = await saveProject('工程B', labelsN(2, lat: 30.0));

    final st = await makeState();
    await st.refreshCollections();
    await st.openCollection(st.collections.firstWhere((m) => m.id == cidA));

    // 在 A 里打几个点，制造撤销快照。
    st.addLabelAtWgs(32.9, 114.9);
    st.addLabelAtWgs(32.901, 114.9);
    expect(st.labels.length, 5);

    await st.openCollection(st.collections.firstWhere((m) => m.id == cidB));
    expect(st.labels.length, 2);
    final before = st.labels.map((l) => l.id).toSet();

    // 切工程后连按两次撤销：只能回到 B 自己的状态。
    st.undoDraft();
    st.undoDraft();

    expect(st.labels.length, 2, reason: '撤销不能把 A 的点搬进 B');
    expect(st.labels.map((l) => l.id).toSet(), before);
    expect(st.labels.every((l) => l.lat < 31), isTrue, reason: 'B 的点在低纬度区');
  });

  test('打开工程后第一次撤销不删末点', () async {
    final cid = await saveProject('单工程', labelsN(3));
    final st = await makeState();
    await st.refreshCollections();
    await st.openCollection(st.collections.firstWhere((m) => m.id == cid));

    st.undoDraft();

    expect(st.labels.length, 3, reason: '刚打开的工程不应被一次撤销删点');
  });

  test('新建工程后撤销，不会恢复上一个工程的点', () async {
    final cid = await saveProject('旧工程', labelsN(4));
    final st = await makeState();
    await st.refreshCollections();
    await st.openCollection(st.collections.firstWhere((m) => m.id == cid));
    st.addLabelAtWgs(32.5, 114.5);

    st.beginNewProject(name: '新工程');
    expect(st.labels, isEmpty);

    st.undoDraft();
    expect(st.labels, isEmpty, reason: '新建工程后的撤销不能把旧工程撤回来');
  });

  test('保存收藏后草稿清空，重启不会再出现一份"未保存草稿"', () async {
    final st = await makeState();
    await st.refreshCollections();
    st.addLabelAtWgs(32.0, 114.0);
    st.addLabelAtWgs(32.001, 114.0);

    final cid = await st.finishCollection(kind: 'label');
    await st.saveIdle;

    expect(st.labels, isEmpty);
    expect(await store.loadDraft(), isEmpty, reason: '保存后 draft.json 必须清空');

    // 模拟重启。
    final st2 = AppState();
    st2.setPrefsForTest(await SharedPreferences.getInstance());
    await st2.init();

    expect(st2.activeCollectionId, isEmpty, reason: '保存完的工程不该再是"编辑中"');
    expect(st2.labels, isEmpty, reason: '重启后不该多出一份同名草稿');
    expect((await store.loadCollection(cid)).length, 2);
  });

  test('重命名正在编辑的工程后保存，名称不会被改回去', () async {
    final cid = await saveProject('旧名字', labelsN(2));
    final st = await makeState();
    await st.refreshCollections();
    await st.openCollection(st.collections.firstWhere((m) => m.id == cid));
    final c = FavTreeController(st);
    await c.ready;

    expect(await c.renameCollectionUndoable(cid, '新名字'), isTrue);
    expect(st.projectName, '新名字', reason: '编辑器名称要跟着收藏一起改');

    await st.finishCollection();
    final metas = await store.loadIndex();
    expect(metas.firstWhere((m) => m.id == cid).name, '新名字',
        reason: '保存不能把刚改的名称写回旧值');
  });

  test('把正在编辑的工程移到别的文件夹后保存，归属不会被搬回去', () async {
    final cid = await saveProject('工程M', labelsN(2));
    final folder = await store.addFolder('目标文件夹');
    final st = await makeState();
    await st.refreshCollections();
    await st.openCollection(st.collections.firstWhere((m) => m.id == cid));
    final c = FavTreeController(st);
    await c.ready;

    expect(await c.moveToFolder(c.find(cid)!, folder.id), isTrue);
    expect(st.folderId, folder.id, reason: '编辑器归属层要跟着移动');

    await st.finishCollection();
    final metas = await store.loadIndex();
    expect(metas.firstWhere((m) => m.id == cid).folder, folder.id,
        reason: '保存不能把工程搬回原文件夹');
  });

  test('删除当前打开的工程后撤销，不会在草稿里留下旧点', () async {
    final cid = await saveProject('待删工程', labelsN(2));
    final st = await makeState();
    await st.refreshCollections();
    await st.openCollection(st.collections.firstWhere((m) => m.id == cid));
    st.addLabelAtWgs(32.2, 114.2);

    await st.deleteCollection(cid);
    expect(st.labels, isEmpty);

    st.undoDraft();
    expect(st.labels, isEmpty, reason: '被删工程的点不能借撤销回到草稿');
  });
}
