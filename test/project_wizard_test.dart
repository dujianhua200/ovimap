import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/design/project_wizard.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';

/// 工程向导（Phase 5）：模板结构 / 生成 / 撤销 / 自定义模板持久化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_wizard');
    LabelStore.instance.setBaseDirForTest(tmp);
    SharedPreferences.setMockInitialValues({});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
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

  group('预设模板', () {
    test('三个预设全部通过校验', () {
      expect(WizardTemplate.presets, hasLength(3));
      for (final t in WizardTemplate.presets) {
        expect(validateWizardTemplate(t), isEmpty, reason: t.name);
      }
    });

    test('通信线路工程：3 文件夹 / 6 工程，层级正确', () {
      final t = WizardTemplate.lineProject;
      final plan = buildWizardPlan(t);
      expect(plan.folderCount, 3);
      expect(plan.projectCount, 6);
      expect(plan.folderSteps.map((s) => s.item.name),
          ['设计', '勘察', '竣工']);
      expect(plan.folderSteps.map((s) => s.depth), [0, 0, 0]);

      final projects = {
        for (final s in plan.projectSteps) s.item.name: s,
      };
      expect(projects.keys,
          containsAll(['杆路', '光缆', '设备', '现场标记', '竣工杆路', '竣工光缆']));
      // 工程挂在正确的文件夹下（depth 1 = 文件夹的子级）。
      for (final n in ['杆路', '光缆', '设备', '现场标记', '竣工杆路', '竣工光缆']) {
        expect(projects[n]!.depth, 1, reason: n);
      }
      final byParent = <String, List<String>>{};
      for (final s in plan.projectSteps) {
        byParent.putIfAbsent(s.item.parentId, () => []).add(s.item.name);
      }
      expect(byParent['f_line_design'], containsAll(['杆路', '光缆', '设备']));
      expect(byParent['f_line_survey'], ['现场标记']);
      expect(byParent['f_line_complete'], containsAll(['竣工杆路', '竣工光缆']));
    });

    test('小区 FTTH / 管线普查：数量与层级', () {
      final ftth = buildWizardPlan(WizardTemplate.ftthProject);
      expect(ftth.folderCount, 3);
      expect(ftth.projectCount, 6);
      expect(
          ftth.projectSteps.map((s) => s.item.name),
          containsAll(
              ['覆盖设计', '配线光缆', '入户光缆', '现场标记', '竣工配线', '竣工入户']));

      final duct = buildWizardPlan(WizardTemplate.ductSurveyProject);
      expect(duct.folderCount, 3);
      expect(duct.projectCount, 4);
      expect(duct.projectSteps.map((s) => s.item.name),
          containsAll(['管道路由', '人手井', '问题标记', '普查成果']));
    });

    test('文件夹嵌套：父先子后拓扑排序', () {
      final t = WizardTemplate(
        id: 't_nest',
        name: '嵌套',
        items: const [
          WizardItem.folder('f_root', '根目录'),
          WizardItem.folder('f_child', '子目录', 'f_root'),
          WizardItem.project('p1', '工程A', 'f_child'),
        ],
      );
      expect(validateWizardTemplate(t), isEmpty);
      final plan = buildWizardPlan(t);
      expect(plan.folderSteps.map((s) => s.item.name), ['根目录', '子目录']);
      expect(plan.folderSteps.map((s) => s.depth), [0, 1]);
      expect(plan.projectSteps.single.depth, 2);
    });
  });

  group('校验', () {
    test('空模板名拒绝', () {
      for (final name in ['', '   ']) {
        final t = WizardTemplate(id: 't1', name: name);
        expect(validateWizardTemplate(t), isNotEmpty);
      }
    });

    test('空条目名 / 父级非法 / 循环引用', () {
      final emptyItem = WizardTemplate(id: 't1', name: 'x', items: const [
        WizardItem.folder('f1', ''),
      ]);
      expect(validateWizardTemplate(emptyItem), isNotEmpty);

      final badParent = WizardTemplate(id: 't1', name: 'x', items: const [
        WizardItem.project('p1', '工程', 'no_such'),
      ]);
      expect(validateWizardTemplate(badParent), isNotEmpty);

      final cycle = WizardTemplate(id: 't1', name: 'x', items: const [
        WizardItem.folder('f1', 'A', 'f2'),
        WizardItem.folder('f2', 'B', 'f1'),
      ]);
      expect(validateWizardTemplate(cycle), isNotEmpty);
    });
  });

  group('applyTemplate 生成', () {
    test('通信线路工程：目录结构正确（层级/名称/数量）', () async {
      final c = await makeController();
      final r = await applyTemplate(c, WizardTemplate.lineProject);

      expect(r.ok, isTrue);
      expect(r.folderIds, hasLength(3));
      expect(r.projectIds, hasLength(6));

      // 顶层：3 个文件夹。
      final topFolders =
          c.folders.where((f) => f.pid.isEmpty).toList();
      expect(topFolders.map((f) => f.name),
          containsAll(['设计', '勘察', '竣工']));

      Future<List<String>> kidProjectNames(String folderName) async {
        final f = c.folders.firstWhere((e) => e.name == folderName);
        final kids = await c.childrenOf(f.id);
        return [
          for (final k in kids)
            if (k.isProject) k.name,
        ];
      }

      expect(await kidProjectNames('设计'), containsAll(['杆路', '光缆', '设备']));
      expect(await kidProjectNames('勘察'), ['现场标记']);
      expect(await kidProjectNames('竣工'), containsAll(['竣工杆路', '竣工光缆']));

      // 生成的工程是空工程（0 点），且落盘。
      for (final cid in r.projectIds) {
        expect(await st.store.loadCollection(cid), isEmpty);
      }
      c.dispose();
    });

    test('生成到指定父文件夹下', () async {
      final c = await makeController();
      final parent = await st.store.addFolder('已有分区');
      await st.refreshCollections();
      final r = await applyTemplate(c, WizardTemplate.ductSurveyProject,
          parentId: parent.id);
      expect(r.ok, isTrue);

      final work =
          c.folders.firstWhere((f) => f.name == '普查');
      expect(work.pid, parent.id);
      final kids = await c.childrenOf(work.id);
      expect(kids.where((k) => k.isProject).map((k) => k.name),
          containsAll(['管道路由', '人手井']));
      c.dispose();
    });

    test('可撤销：undo 后本次创建的全部消失；redo 可恢复', () async {
      final c = await makeController();
      final beforeFolders = c.folders.length;
      final beforeProjects = c.projects.length;

      final r = await applyTemplate(c, WizardTemplate.lineProject);
      expect(r.ok, isTrue);
      expect(c.folders.length, beforeFolders + 3);

      // undo：整批回退。
      expect(await st.undoStack.undo(), isTrue);
      expect(c.folders.length, beforeFolders);
      expect(c.projects.length, beforeProjects);
      expect(c.folders.where((f) => f.name == '设计'), isEmpty);

      // redo：重新生成（新 id，但结构一致）。
      expect(await st.undoStack.redo(), isTrue);
      expect(c.folders.length, beforeFolders + 3);
      expect(c.projects.length, beforeProjects + 6);
      c.dispose();
    });

    test('空模板拒绝生成', () async {
      final c = await makeController();
      final t = WizardTemplate(id: 't_empty', name: '空模板');
      expect(() => applyTemplate(c, t), throwsArgumentError);
      c.dispose();
    });

    test('只记一条撤销命令', () async {
      final c = await makeController();
      final n0 = st.undoStack.undoCount;
      await applyTemplate(c, WizardTemplate.ductSurveyProject);
      expect(st.undoStack.undoCount, n0 + 1);
      expect(st.undoStack.lastUndoDescription, contains('管线普查工程'));
      c.dispose();
    });
  });

  group('WizardTemplateStore 自定义模板持久化', () {
    WizardTemplate mkCustom(String name) => WizardTemplate(
          id: WizardTemplate.newId('wt'),
          name: name,
          items: const [
            WizardItem.folder('cf1', '外业'),
            WizardItem.project('cp1', '杆路', 'cf1'),
          ],
        );

    test('存取 round-trip：新增 / 更新 / 删除', () async {
      var store = await WizardTemplateStore.load(st.store);
      expect(store.customTemplates, isEmpty);
      expect(store.allTemplates(), hasLength(3)); // 仅 3 个预设

      final t = mkCustom('我的模板');
      await store.saveTemplate(t);

      store = await WizardTemplateStore.load(st.store);
      expect(store.customTemplates, hasLength(1));
      final loaded = store.customTemplates.single;
      expect(loaded.name, '我的模板');
      expect(loaded.items, hasLength(2));
      expect(loaded.items.first.name, '外业');
      expect(store.allTemplates(), hasLength(4));

      // 更新。
      await store.saveTemplate(loaded.copyWith(name: '改名后'));
      store = await WizardTemplateStore.load(st.store);
      expect(store.customTemplates.single.name, '改名后');

      // 删除。
      await store.deleteTemplate(loaded.id);
      store = await WizardTemplateStore.load(st.store);
      expect(store.customTemplates, isEmpty);
    });

    test('空模板名拒绝（抛 ArgumentError，不落盘）', () async {
      final store = await WizardTemplateStore.load(st.store);
      final t = mkCustom('   ');
      expect(() => store.saveTemplate(t), throwsArgumentError);
      final reloaded = await WizardTemplateStore.load(st.store);
      expect(reloaded.customTemplates, isEmpty);
    });

    test('预设模板不可保存为自定义', () async {
      final store = await WizardTemplateStore.load(st.store);
      expect(
          () => store.saveTemplate(WizardTemplate.lineProject),
          throwsArgumentError);
    });

    test('损坏文件不炸：返回空 store', () async {
      final dir = await st.store.labelsDir();
      await File('${dir.path}/wizard_templates.json')
          .writeAsString('not json {{{');
      final store = await WizardTemplateStore.load(st.store);
      expect(store.customTemplates, isEmpty);
      expect(store.allTemplates(), hasLength(3));
    });
  });
}
