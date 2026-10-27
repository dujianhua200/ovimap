// 交互逻辑护栏（v5）：让模式切换符合"人会怎么操作"。
//
// 覆盖本轮修正的四类问题：
//   1. 打开工程默认浏览，不再一点地图就落点（误改已保存工程）；
//   2. 标记模式与其它工具互斥，标记完回到浏览，不会继续连线；
//   3. 切换/清空工程时，标记、拓扑、选择集等一次性状态一起退场；
//   4. 新建工程一次设定名称/模板/编号，直接进入打点。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/models/project_template.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/label_marker.dart';
import 'package:ovimap/ui/unsaved_draft_guard.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fs_cleanup.dart';

final store = LabelStore.instance;

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 80));

List<MapLabel> labelsN(int n) => [
      for (var i = 0; i < n; i++)
        MapLabel(typeId: 'pole', seq: i + 1, lat: 32.0 + i * 0.001, lon: 114.0),
    ];

Future<AppState> makeState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final st = AppState();
  st.setPrefsForTest(await SharedPreferences.getInstance());
  return st;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_ux_v5');
    store.setBaseDirForTest(dir);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    AppPaths.clearForTest();
    await deleteTempDirResilient(dir);
  });

  group('打开工程：默认浏览，不误落点', () {
    test('openCollection 后 mode=view，点数据已加载', () async {
      final cid = await store.finishCollection(
        name: '杆路A',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(2),
      );
      final st = await makeState();
      await st.refreshCollections();
      await st.openCollection(st.collections.firstWhere((m) => m.id == cid));

      expect(st.labels.length, 2);
      expect(st.mode, AppMode.view,
          reason: '打开工程是查看，不应直接进入打点；编辑必须显式点「打点」');
    });

    test('打开工程会清掉上一个工程的标记/拓扑/选择集', () async {
      final cid = await store.finishCollection(
        name: '杆路B',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(1),
      );
      final st = await makeState();
      await st.refreshCollections();
      st.markMode = true;
      st.selectedIds.add('stale');
      st.topoCid = 'old';
      st.topoColl = labelsN(1);
      st.topoSelId = 'old-pt';

      await st.openCollection(st.collections.firstWhere((m) => m.id == cid));

      expect(st.markMode, isFalse);
      expect(st.selectedIds, isEmpty);
      expect(st.topoCid, isEmpty);
      expect(st.topoColl, isEmpty);
      expect(st.topoSelId, isNull);
    });
  });

  group('工具模式互斥', () {
    test('setMode 会取消标记模式（点「打点」不会被标记截胡）', () async {
      final st = await makeState();
      st.markMode = true;
      st.mode = AppMode.view;

      st.setMode(AppMode.edit);

      expect(st.markMode, isFalse);
      expect(st.mode, AppMode.edit);
    });

    test('开启标记模式会退回浏览并清掉拓扑工程', () async {
      final st = await makeState();
      st.mode = AppMode.topoLink;
      st.topoCid = 'c1';
      st.topoColl = labelsN(1);

      st.toggleMarkMode();

      expect(st.markMode, isTrue);
      expect(st.mode, AppMode.view);
      expect(st.topoCid, isEmpty);
      expect(st.topoColl, isEmpty);
    });

    test('离开拓扑模式会清掉 topoCid（否则 _saveDraft 不再写回收藏）', () async {
      final st = await makeState();
      st.mode = AppMode.topoLink;
      st.topoCid = 'c1';
      st.topoColl = labelsN(1);

      st.setMode(AppMode.edit);

      expect(st.topoCid, isEmpty);
      expect(st.topoColl, isEmpty);
      expect(st.mode, AppMode.edit);
    });

    test('标记模式下换符号保持标记模式；普通模式下换符号进入打点', () async {
      final st = await makeState();
      st.mode = AppMode.view;
      st.markMode = true;
      st.setType(LabelType.fromId('pipe'));
      expect(st.markMode, isTrue, reason: '换符号只是换"要放的符号"，不能退出标记');
      expect(st.mode, AppMode.view);

      st.markMode = false;
      st.mode = AppMode.view;
      st.setType(LabelType.fromId('concrete'));
      expect(st.mode, AppMode.edit);
    });

    test('标记落点后回到浏览（下一次点击不会继续连线）', () async {
      final st = await makeState();
      st.toggleMarkMode();
      expect(st.markMode, isTrue);

      await st.addMarkAtWgs(32.0, 114.0);

      expect(st.markMode, isFalse);
      expect(st.mode, AppMode.view);
      await _settle();
    });
  });

  group('新建工程引导', () {
    test('一次设定名称/模板/编号，并直接进入打点', () async {
      final st = await makeState();
      // 先造一个"上一个工程"的残留，确认新建会清干净。
      st.labels.addAll(labelsN(2));
      st.mode = AppMode.topoLink;
      st.topoCid = 'old';
      st.markMode = true;

      st.beginNewProject(
        name: '李庄架空光缆改造',
        template: ProjectTemplate.byId('aerial'),
        autoNumber: true,
        prefix: 'G',
      );

      expect(st.projectName, '李庄架空光缆改造');
      expect(st.labels, isEmpty, reason: '新建工程必须清掉旧草稿');
      expect(st.mode, AppMode.edit, reason: '新建后直接进入打点');
      expect(st.markMode, isFalse);
      expect(st.topoCid, isEmpty);
      expect(st.templateId, 'aerial');
      expect(st.curType.id, 'concrete', reason: '架空模板默认水泥杆');
      expect(st.defSegKind, 1, reason: '架空模板默认敷设方式=架空');
      expect(st.autoNumber, isTrue);
      expect(st.numPrefix, 'G');
      expect(st.editModeName, 'design', reason: '新工程一律从设计模式开始');
      await _settle();
    });

    test('空白模板沿用当前符号，前缀回落到 GK，并清掉上次模板标记', () async {
      final st = await makeState();
      st.applyTemplate(ProjectTemplate.byId('aerial')!);
      expect(st.templateId, 'aerial');

      st.beginNewProject(name: '空白工程', template: null, prefix: '');

      expect(st.templateId, isNull, reason: '选空白后下次新建不应再预选架空模板');
      expect(st.numPrefix, 'GK');
      expect(st.mode, AppMode.edit);
    });
  });

  group('未保存草稿判定（切换工程护栏）', () {
    test('有点且未存成工程 = 真；保存或打开工程后 = 假', () async {
      final st = await makeState();
      expect(st.hasUnsavedDraft, isFalse, reason: '空草稿无需提示');

      st.labels.addAll(labelsN(2));
      expect(st.hasUnsavedDraft, isTrue,
          reason: '有未保存点位，切换工程前必须提示');

      st.projectName = '草稿A';
      await st.finishCollection();
      expect(st.hasUnsavedDraft, isFalse,
          reason: '已存成工程，草稿已被接管，不再算"未保存"');
      expect(st.activeCollectionId, isEmpty);
      await _settle();
    });

    test('只有 .ovimap 会触发草稿替换护栏', () {
      expect(containsProjectFile(<String>['/tmp/a.ovimap']), isTrue);
      expect(containsProjectFile(<String>['/tmp/A.OVIMAP']), isTrue);
      expect(containsProjectFile(<String>['/tmp/a.geojson', '/tmp/b.json']),
          isFalse);
    });
  });

  group('删除工程', () {
    test('外部导入的工程删除后，草稿与地图数据一起清掉', () async {
      final label =
          MapLabel(typeId: 'concrete', seq: 1, lat: 32.0, lon: 114.0, name: 'G-1');
      final file = File('${dir.path}/外部导入.ovimap');
      await file.writeAsString(jsonEncode({
        'id': 'imported',
        'name': '外部导入',
        'kind': 'label',
        'editMode': 'design',
        'labels': [label.toJson()],
      }));

      final st = await makeState();
      final msg = await st.importProjectFile(file.path);
      expect(msg, contains('已导入并打开'));
      expect(st.labels.length, 1, reason: '导入后点会进入草稿，供继续编辑');

      final cid = st.activeCollectionId;
      expect(cid, isNotEmpty);
      // 模拟地图上的可见叠加层（导入后通常同时可见）。
      st.visibleCids.add(cid);
      st.overlayLabels[cid] = await st.store.loadCollection(cid);

      await st.deleteCollection(cid);

      expect(st.labels, isEmpty,
          reason: '删除当前打开的工程必须同时关闭草稿，否则地图仍显示这些点');
      expect(st.activeCollectionId, isEmpty,
          reason: '删除后不能继续把编辑写回已删除的工程');
      expect(st.overlayLabels.containsKey(cid), isFalse);
      expect(st.visibleCids.contains(cid), isFalse);
      expect(st.mode, AppMode.view);
      expect(st.prefs.getString(AppState.prefVisible) ?? '', isNot(contains(cid)),
          reason: '可见集合要落盘，重启后不能再加载已删除工程');
      await _settle();
    });
  });

  group('符号', () {
    test('水泥杆是无字圆圈（dot），圆内不再挤点名/电字', () {
      expect(LabelType.concrete.symbol, isEmpty);
      expect(LabelType.concrete.shape, 'dot');

      final named = MapLabel(typeId: 'concrete', name: 'G-1');
      expect(effectiveSymbolStyle(named).$3, isEmpty,
          reason: '点名画在圆下方，圆内保持纯圆圈');

      final overridden = MapLabel(typeId: 'concrete', symText: 'G');
      expect(effectiveSymbolStyle(overridden).$3, 'G',
          reason: '用户显式设置的符号字仍然生效');

      final pipe = MapLabel(typeId: 'pipe', name: 'P1');
      expect(effectiveSymbolStyle(pipe).$3, 'P1',
          reason: '其它杆/管类型维持原口径（名称优先）');
    });
  });

  group('重启后的工程归属', () {
    test('编辑已保存工程后重启：仍归属原工程，保存不产生重复工程', () async {
      final cid = await store.finishCollection(
        name: '编辑中工程',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(1),
      );
      final st1 = await makeState();
      await st1.refreshCollections();
      await st1.openCollection(
          st1.collections.firstWhere((m) => m.id == cid));
      st1.addLabelAtWgs(32.5, 114.5);
      await _settle();

      // 模拟重启。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final st2 = AppState();
      st2.setPrefsForTest(await SharedPreferences.getInstance());
      await st2.init();

      expect(st2.activeCollectionId, cid, reason: '重启后应恢复正在编辑哪个工程');
      expect(st2.labels.length, 2);
      expect(st2.mode, AppMode.view, reason: '重启后仍是浏览态，点「打点」才继续');

      await st2.finishCollection();

      final metas = await store.loadIndex();
      expect(metas.where((m) => m.id == cid).length, 1,
          reason: '保存应覆盖原工程，不能新增一个同名重复工程');
      expect((await store.loadCollection(cid)).length, 2);
    });

    test('重启时原工程已被删除：保留点位作为未保存草稿，不写回旧 cid', () async {
      final cid = await store.finishCollection(
        name: '将被删除的工程',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(1),
      );
      final st1 = await makeState();
      await st1.refreshCollections();
      await st1.openCollection(
          st1.collections.firstWhere((m) => m.id == cid));
      st1.addLabelAtWgs(32.5, 114.5);
      await _settle();
      // 模拟"应用关闭期间工程被删"（直接删文件/索引，不走 AppState）。
      await store.deleteCollection(cid);
      await _settle();

      final st2 = AppState();
      st2.setPrefsForTest(await SharedPreferences.getInstance());
      await st2.init();

      expect(st2.activeCollectionId, isEmpty);
      expect(st2.labels.length, 2, reason: '现场点位不能因为工程被删就丢掉');
      expect(st2.hasUnsavedDraft, isTrue);
    });
  });

  group('编辑中的工程不重复渲染', () {
    test('打开中的工程不算叠加层；删点后叠加缓存同步', () async {
      final cid = await store.finishCollection(
        name: '工程A',
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: labelsN(2),
      );
      final st = await makeState();
      await st.refreshCollections();
      await st.openCollection(st.collections.firstWhere((m) => m.id == cid));
      st.visibleCids.add(cid);
      st.overlayLabels[cid] = await st.store.loadCollection(cid);

      expect(st.isOverlayVisible(cid), isFalse,
          reason: '编辑中的工程由草稿层渲染，叠加层不应再画一份');
      expect(st.isOverlayVisible('other'), isFalse);
      st.visibleCids.add('other');
      expect(st.isOverlayVisible('other'), isTrue);

      // 删掉草稿里的一个点：叠加层缓存也要变 1，切走后不会留下旧点。
      st.removeLabel(st.labels.first);
      await _settle();
      expect(st.overlayLabels[cid]!.length, 1);
    });
  });

  group('自动编号', () {
    test('沿折线自动布杆：杆位落在路径上，编号接最大号', () async {
      final st = await makeState();
      st.labels.addAll([
        MapLabel(
            typeId: 'concrete', name: 'G-1', lat: 32.0, lon: 114.0, seq: 1),
        MapLabel(
            typeId: 'concrete', name: 'G-5', lat: 32.0, lon: 114.001, seq: 2),
      ]);
      final path = <List<double>>[
        [32.0, 114.0],
        [32.0, 114.01],
        [32.01, 114.01],
      ];

      final n = st.autoPlacePolesAlongPath(
          path: path, spacingM: 50, typeId: 'concrete', prefix: 'G');

      expect(n, greaterThan(2));
      final added = st.labels.sublist(2);
      expect(added.length, n);
      expect(added.first.name, 'G-6', reason: '接已有最大号 G-5，而不是按数量');
      expect(added.first.lat, closeTo(32.0, 1e-9));
      expect(added.first.lon, closeTo(114.0, 1e-9));
      expect(added.last.lat, closeTo(32.01, 1e-9));
      expect(added.last.lon, closeTo(114.01, 1e-9));
      for (final l in added) {
        final onFirst = (l.lat - 32.0).abs() < 1e-7;
        final onSecond = (l.lon - 114.01).abs() < 1e-7;
        expect(onFirst || onSecond, isTrue,
            reason: '自动布杆点必须落在已画折线上');
      }
    });

    test('用已有最大号 +1，删掉中间点后不复用编号', () async {
      final st = await makeState();
      st.setAutoNumber(true, 'G');
      st.setType(LabelType.concrete);
      st.addLabelAtWgs(32.0, 114.0);
      st.addLabelAtWgs(32.001, 114.0);
      st.addLabelAtWgs(32.002, 114.0);
      expect(st.labels.map((e) => e.name).toList(), ['G-1', 'G-2', 'G-3']);

      st.removeLabel(st.labels[1]); // 删掉 G-2
      await _settle();
      st.addLabelAtWgs(32.003, 114.0);

      expect(st.labels.last.name, 'G-4',
          reason: '编号应按最大号递增；按剩余数量计数会与 G-3 重号');
    });
  });

  group('清空/结束采集', () {
    test('clearDraft 清掉选择集，避免"删了但选中数还在"', () async {
      final st = await makeState();
      st.labels.addAll(labelsN(2));
      st.selectedIds.add(st.labels.first.id);

      st.clearDraft();

      expect(st.labels, isEmpty);
      expect(st.selectedIds, isEmpty);
    });

    test('结束打点（setMode view）保留草稿', () async {
      final st = await makeState();
      st.labels.addAll(labelsN(3));
      st.setMode(AppMode.edit);

      st.setMode(AppMode.view);

      expect(st.labels.length, 3, reason: 'Esc 只退出模式，不能丢草稿');
      expect(st.mode, AppMode.view);
    });
  });
}
