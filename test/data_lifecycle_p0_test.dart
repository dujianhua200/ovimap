// P0/P1 数据生命周期修复（Worker A）回归测试。
//
// 覆盖：
//   P0-1  openCollection/startNewDraft/finishCollection 加载或重置 fiberLinks
//        （跨工程泄漏）
//   P0-2  finishCollection / moveLabelToProject / _appendToMarkBook 整文件重写
//         带上 fiberLinks
//   P0-3  topoTap 后再草稿编辑，topoParentId 不被 _saveDraft 全量覆盖擦除
//   P0-4  fiberLinks 为空也写入（空数组），清空后旧值不"复活"
//   P0-5  resolveExportData：两处导出入口的统一数据源（以磁盘文件为准）
//   P0-9  _saveDraft 串行化：旧快照不覆盖新快照（saveIdle 排空后磁盘==内存）
//   P0-10 工程文件（.ovimap）导入读回 fiberLinks
//   P1-7  markHere 参与撤销快照
//   P1-17 持久化异常记入 persistErrors，不再静默吞掉
//   P1-18 onRemoteApplied 重载 fiberLinks / topoColl
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/device_identity.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/sync/sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fs_cleanup.dart';

final store = LabelStore.instance;

List<MapLabel> labelsN(int n, {String typeId = 'pole'}) => [
      for (var i = 0; i < n; i++)
        MapLabel(typeId: typeId, seq: i + 1, lat: 32.0 + i * 0.001, lon: 114.0),
    ];

Map<String, dynamic> linkJson(String id, String from, String to) =>
    FiberLink(id: id, fromDeviceId: from, toDeviceId: to, cores: 24,
            cableModel: 'GYTS')
        .toJson();

Future<AppState> makeState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final st = AppState();
  st.setPrefsForTest(await SharedPreferences.getInstance());
  return st;
}

Future<String> diskFiberLinksRaw(String dir, String cid) async {
  final f = File('$dir/labels/collection_$cid.json');
  final o =
      jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  return jsonEncode(o['fiberLinks']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_datalife');
    store.setBaseDirForTest(dir);
    store.recentPersistErrors.clear();
  });

  tearDown(() async {
    AppPaths.clearForTest();
    await deleteTempDirResilient(dir);
  });

  group('P0-1 fiberLinks 跨工程泄漏', () {
    test('打开工程B后，内存连线是B的（A的不泄漏）', () async {
      final cidA = await store.finishCollection(
        name: '工程A',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(1),
        fiberLinks: [linkJson('la', 'a1', 'a2')],
      );
      final cidB = await store.finishCollection(
        name: '工程B',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(1),
      );
      final st = await makeState();
      await st.refreshCollections();
      final metas = await store.loadIndex();

      await st.openCollection(metas.firstWhere((m) => m.id == cidA));
      expect(st.fiberLinks.map((e) => e.id), ['la']);

      await st.openCollection(metas.firstWhere((m) => m.id == cidB));
      expect(st.fiberLinks, isEmpty,
          reason: '打开B后内存连线必须是B的（空），不能残留A的');
      expect(cidB, isNot(cidA));
    });

    test('startNewDraft 清空内存连线且草稿文件写空数组', () async {
      final cidA = await store.finishCollection(
        name: '工程A',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(1),
        fiberLinks: [linkJson('la', 'a1', 'a2')],
      );
      final st = await makeState();
      await st.refreshCollections();
      final metas = await store.loadIndex();
      await st.openCollection(metas.firstWhere((m) => m.id == cidA));
      expect(st.fiberLinks, isNotEmpty);

      st.startNewDraft();
      await st.saveIdle;
      expect(st.fiberLinks, isEmpty, reason: '新建空白工程必须重置连线');
      final draft = jsonDecode(
              await File('${dir.path}/labels/draft.json').readAsString())
          as Map<String, dynamic>;
      expect(draft['fiberLinks'], isA<List>());
      expect((draft['fiberLinks'] as List), isEmpty);
    });

    test('finishCollection 后内存连线复位', () async {
      final st = await makeState();
      st.updateFiberLinks([
        FiberLink(id: 'lx', fromDeviceId: 'p1', toDeviceId: 'p2')
      ]);
      await st.saveIdle;
      st.projectName = '新工程';
      final cid = await st.finishCollection();
      expect(st.fiberLinks, isEmpty, reason: '保存后内存连线随工程复位');
      // 文件里要有这条连线（P0-2 联动）。
      final links = await store.loadCollectionFiberLinks(cid);
      expect(links.map((e) => e['id']), ['lx']);
    });
  });

  group('P0-2 整文件重写带上 fiberLinks', () {
    test('AppState.finishCollection 落盘含连线', () async {
      final st = await makeState();
      st.labels = labelsN(2);
      st.updateFiberLinks(
          [FiberLink(id: 'l1', fromDeviceId: 'd1', toDeviceId: 'd2')]);
      await st.saveIdle;
      st.projectName = '带连线工程';
      final cid = await st.finishCollection();
      final links = await store.loadCollectionFiberLinks(cid);
      expect(links.length, 1);
      expect(links.first['id'], 'l1');
    });

    test('moveLabelToProject 保留双方工程的连线', () async {
      final cidA = await store.finishCollection(
        name: '源工程',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(2),
        fiberLinks: [linkJson('la', 'a1', 'a2')],
      );
      final cidB = await store.finishCollection(
        name: '目标工程',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(1),
        fiberLinks: [linkJson('lb', 'b1', 'b2')],
      );
      final st = await makeState();
      await st.refreshCollections();
      final moving = (await store.loadCollection(cidA)).first;
      await st.moveLabelToProject(
          fromCid: cidA, label: moving, toCid: cidB);

      final linksA = await store.loadCollectionFiberLinks(cidA);
      final linksB = await store.loadCollectionFiberLinks(cidB);
      expect(linksA.map((e) => e['id']), ['la'],
          reason: '源工程重写后连线不能丢');
      expect(linksB.map((e) => e['id']), ['lb'],
          reason: '目标工程重写后连线不能丢');
      expect((await store.loadCollection(cidB)).length, 2);
    });

    test('_appendToMarkBook（标记模式）保留「标记」收藏的连线', () async {
      final st = await makeState();
      st.markMode = true;
      await st.addMarkAtWgs(32.0, 114.0);
      final markCid =
          (await store.loadIndex()).firstWhere((m) => m.name == '标记').id;
      // 手工给标记收藏加一条连线，模拟"之前存过"。
      await store.saveCollectionLabels(
        markCid,
        await store.loadCollection(markCid),
        fiberLinks: [linkJson('lm', 'm1', 'm2')],
      );
      st.markMode = true;
      await st.addMarkAtWgs(32.5, 114.5);

      final links = await store.loadCollectionFiberLinks(markCid);
      expect(links.map((e) => e['id']), ['lm'],
          reason: '追加标记点整文件重写后，连线不能丢');
      expect((await store.loadCollection(markCid)).length, 2);
    });
  });

  group('P0-3 topoParentId 不被草稿编辑擦除', () {
    test('topoTap 连线后补点，磁盘文件的 topoParentId 仍在', () async {
      final cid = await store.finishCollection(
        name: '拓扑工程',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(2, typeId: 'fiberbox'),
      );
      final st = await makeState();
      await st.refreshCollections();
      final metas = await store.loadIndex();
      // 打开编辑（st.labels 与 topoColl 是两份实例，复现擦除场景）。
      await st.openCollection(metas.firstWhere((m) => m.id == cid));
      expect(await st.startTopoLink(metas.firstWhere((m) => m.id == cid)),
          isTrue);
      final boxes = st.topoColl;
      expect(boxes.length, 2);
      st.topoTap(boxes[0]); // 选起点
      final msg = st.topoTap(boxes[1]); // 连线
      expect(msg.contains('已连接'), isTrue);

      // 退出拓扑模式后"补个点"（走 _saveDraft 全量覆盖收藏文件）。
      st.endTopoLink();
      st.addLabelAtWgs(33.0, 115.0);
      await st.saveIdle;

      final onDisk = await store.loadCollection(cid);
      final child =
          onDisk.firstWhere((l) => l.id == boxes[1].id);
      expect(child.topoParentId, boxes[0].id,
          reason: '草稿编辑后，拓扑父子关系必须还在');
      expect(onDisk.length, 3);
    });

    test('topoTap 只改 labels，不丢该工程已有的 fiberLinks', () async {
      final cid = await store.finishCollection(
        name: '拓扑+连线',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(2, typeId: 'fiberbox'),
        fiberLinks: [linkJson('kl', 'x', 'y')],
      );
      final st = await makeState();
      await st.refreshCollections();
      final metas = await store.loadIndex();
      await st.openCollection(metas.firstWhere((m) => m.id == cid));
      expect(await st.startTopoLink(metas.firstWhere((m) => m.id == cid)),
          isTrue);
      final boxes = st.topoColl;
      st.topoTap(boxes[0]);
      st.topoTap(boxes[1]);
      await st.saveIdle;

      expect((await store.loadCollectionFiberLinks(cid)).map((e) => e['id']),
          ['kl'],
          reason: 'topo 连线不能把人工 fiberLinks 抹掉');
    });
  });

  group('P0-4 空连线也写入（旧值不复活）', () {    test('清空连线后保存，文件里是空数组而非残留旧值', () async {
      final st = await makeState();
      st.updateFiberLinks(
          [FiberLink(id: 'l1', fromDeviceId: 'd1', toDeviceId: 'd2')]);
      await st.saveIdle;
      st.projectName = '先后清空';
      final cid = await st.finishCollection();
      // 重新打开，把连线清掉再保存。
      await st.refreshCollections();
      final metas = await store.loadIndex();
      await st.openCollection(metas.firstWhere((m) => m.id == cid));
      expect(st.fiberLinks.length, 1);
      st.updateFiberLinks([]);
      await st.saveIdle;

      final raw = await diskFiberLinksRaw(dir.path, cid);
      expect(raw, '[]', reason: '清空后文件必须是空数组，旧连线不许复活');
      final draft = jsonDecode(
              await File('${dir.path}/labels/draft.json').readAsString())
          as Map<String, dynamic>;
      expect(jsonEncode(draft['fiberLinks']), '[]');
    });

    test('不传 fiberLinks 的写盘路径保留原有连线（防误删回归）', () async {
      final cid = await store.finishCollection(
        name: '保留连线',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(2),
        fiberLinks: [linkJson('keep', 'k1', 'k2')],
      );
      // saveCollectionLabels 不传 fiberLinks → 保留。
      await store.saveCollectionLabels(cid, await store.loadCollection(cid));
      expect((await store.loadCollectionFiberLinks(cid)).map((e) => e['id']),
          ['keep']);

      // saveDraft 不传 fiberLinks → 保留草稿原有连线。
      await store.saveDraft([], 'x', '', 'design', [linkJson('kd', 'a', 'b')]);
      await store.saveDraft(labelsN(1), 'x', '', 'design');
      expect((await store.loadFiberLinks()).map((e) => e['id']), ['kd']);
    });
  });

  group('P0-5 resolveExportData 统一口径', () {
    test('返回磁盘文件的 labels+fiberLinks+name', () async {
      final cid = await store.finishCollection(
        name: '导出工程',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(3),
        fiberLinks: [linkJson('le', 'e1', 'e2')],
      );
      final st = await makeState();
      final data = await st.resolveExportData(cid);
      expect(data.labels.length, 3);
      expect(data.fiberLinks.map((e) => e.id), ['le']);
      expect(data.name, '导出工程');
    });
  });

  group('P0-9 _saveDraft 串行化', () {
    test('连续打点+删点后排空队列，磁盘==内存（旧快照不覆盖新快照）', () async {
      final st = await makeState();
      // 刻意不等：三次 _saveDraft 入队。
      st.addLabelAtWgs(32.0, 114.0);
      st.addLabelAtWgs(32.001, 114.0);
      st.removeLabel(st.labels.last);
      await st.saveIdle;

      final onDisk = await store.loadDraft();
      expect(onDisk.length, st.labels.length);
      expect(onDisk.length, 1);
      // saveIdle 可重复等待且幂等。
      await st.saveIdle;
      expect((await store.loadDraft()).length, 1);
    });
  });

  group('P0-10 .ovimap 导入读回 fiberLinks', () {
    test('含连线的工程文件导入后，连线进内存也进文件', () async {
      final f = File('${dir.path}/with_links.ovimap');
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'id': 'orig',
        'name': '连线工程',
        'kind': 'label',
        'folderId': '',
        'editMode': 'design',
        'labels': [
          for (var i = 0; i < 2; i++)
            <String, dynamic>{
              'id': 'pt-$i',
              'typeId': 'fiberbox',
              'seq': i + 1,
              'lat': 32.0 + i * 0.001,
              'lon': 114.0,
            },
        ],
        'fiberLinks': [linkJson('li', 'pt-0', 'pt-1')],
      }));
      final st = await makeState();
      final msg = await st.importProjectFile(f.path);
      expect(msg.contains('已导入并打开工程「连线工程」'), isTrue);
      expect(msg.contains('1 条连线'), isTrue);
      expect(st.fiberLinks.map((e) => e.id), ['li'],
          reason: '导入后 openCollection 应加载连线到内存');
      final links =
          await store.loadCollectionFiberLinks(st.activeCollectionId);
      expect(links.map((e) => e['id']), ['li'],
          reason: '导入落盘文件必须含连线');
    });
  });

  group('P1-7 markHere 参与撤销', () {
    test('打点→我在这→撤销：只撤掉"我在这"那一点', () async {
      final st = await makeState();
      st.addLabelAtWgs(32.0, 114.0);
      st.markHere();
      expect(st.labels.length, 2);
      st.undoDraft();
      expect(st.labels.length, 1,
          reason: '一次撤销只应回退 markHere 的一点，不能连带删掉前一点');
      expect(st.labels.single.name, isNot('我在这'));
    });
  });

  group('P1-17 持久化异常上报', () {
    test('写盘失败记入 persistErrors（不再静默）', () async {
      // 用普通文件占住 labels 目录位置，制造写盘失败。
      File('${dir.path}/labels').writeAsStringSync('占位');
      final before = store.recentPersistErrors.length;
      await store.saveDraft([], 'x', '', 'design', []);
      expect(store.recentPersistErrors.length, greaterThan(before));
      expect(store.recentPersistErrors.last.contains('saveDraft'), isTrue);
      // AppState 对外暴露同一份记录。
      final st = await makeState();
      expect(st.persistErrors, isNotEmpty);
      // 恢复现场，不影响其它用例。
      File('${dir.path}/labels').deleteSync();
    });
  });

  group('P1-18 onRemoteApplied 重载连线与拓扑', () {
    test('远端落盘后回调：fiberLinks 与 topoColl 一起重载', () async {
      final cid = await store.finishCollection(
        name: '同步工程',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(2, typeId: 'fiberbox'),
        fiberLinks: [linkJson('old', 'x1', 'x2')],
      );
      final st = await makeState();
      final sc = SyncController(
        store: store,
        identity: DeviceIdentity.forTest(token: '', serverBase: ''),
      )..autoPoll = false;
      st.attachSyncController(sc);
      await st.refreshCollections();
      final metas = await store.loadIndex();
      await st.openCollection(metas.firstWhere((m) => m.id == cid));
      expect(st.fiberLinks.map((e) => e.id), ['old']);
      expect(await st.startTopoLink(metas.firstWhere((m) => m.id == cid)),
          isTrue);

      // 模拟远端落盘：直接改文件（连线换新 + topoParentId 变化）。
      final ls = await store.loadCollection(cid);
      ls[1].topoParentId = ls[0].id;
      await store.saveCollectionLabels(cid, ls,
          fiberLinks: [linkJson('new', 'y1', 'y2')]);

      await sc.onRemoteApplied!(cid);

      expect(st.fiberLinks.map((e) => e.id), ['new'],
          reason: 'onRemoteApplied 必须重载 fiberLinks');
      expect(st.topoColl.firstWhere((l) => l.id == ls[1].id).topoParentId,
          ls[0].id,
          reason: 'onRemoteApplied 必须重载 topoColl');
      sc.dispose();
    });
  });
}
