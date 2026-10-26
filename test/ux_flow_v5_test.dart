// 交互逻辑护栏（v5）：让模式切换符合"人会怎么操作"。
//
// 覆盖本轮修正的四类问题：
//   1. 打开工程默认浏览，不再一点地图就落点（误改已保存工程）；
//   2. 标记模式与其它工具互斥，标记完回到浏览，不会继续连线；
//   3. 切换/清空工程时，标记、拓扑、选择集等一次性状态一起退场；
//   4. 新建工程一次设定名称/模板/编号，直接进入打点。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/models/project_template.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
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
