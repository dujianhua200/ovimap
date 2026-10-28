import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/import/import_model.dart';
import 'package:ovimap/import/tree_import.dart';
import 'package:ovimap/models/fav_node.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';

/// 导入入树（lib/import/tree_import.dart）端到端：
///
/// 手写 [ImportParseResult]（两层 Folder 路径 + 根级单元混合）
/// → [importParsedResult] → 断言树结构（文件夹嵌套层级、工程归属文件夹、
/// labels 数量、lineGroupId 保留）→ undo → 断言本次建的文件夹/工程全部消失
/// （一条撤销完全回退）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;
  late LabelStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_import_tree');
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

  MapLabel pt(
    String name, {
    String gid = '',
    double lat = 31.0,
    double lon = 121.0,
  }) => MapLabel(
    typeId: 'concrete',
    lat: lat,
    lon: lon,
    name: name,
    lineGroupId: gid,
  );

  /// 两层 Folder 路径 + 根级单元混合：
  /// 北京/朝阳（2 线点 + 1 单点）、北京/海淀（1 单点）、根级工程（1 单点）。
  ImportParseResult sample() => ImportParseResult(
    units: [
      ImportUnit(
        folderPath: const ['北京', '朝阳'],
        name: '朝阳',
        labels: [
          pt('G001', gid: 'g1', lat: 31.0, lon: 121.0),
          pt('G002', gid: 'g1', lat: 31.001, lon: 121.001),
          pt('单点A', lat: 31.002, lon: 121.002),
        ],
      ),
      ImportUnit(
        folderPath: const ['北京', '海淀'],
        name: '海淀',
        labels: [pt('单点B', lat: 31.01, lon: 121.01)],
      ),
      ImportUnit(
        folderPath: const [],
        name: '根级工程',
        labels: [pt('根点', lat: 31.02, lon: 121.02)],
      ),
    ],
  );

  /// 把整棵树拍平成：文件夹名 → 直属子节点（"folder:名" / "project:名"）。
  Future<Map<String, List<String>>> flatTree(FavTreeController c) async {
    final out = <String, List<String>>{};
    Future<void> walk(FavNode node) async {
      final kids = await c.childrenOf(node.id);
      out[node.name] = kids.map((k) => '${k.kind.name}:${k.name}').toList()
        ..sort();
      for (final k in kids) {
        if (k.kind == FavKind.folder) await walk(k);
      }
    }

    for (final r in c.roots) {
      if (r.kind == FavKind.folder) {
        await walk(r);
      } else {
        out['<root>'] = (out['<root>'] ?? [])..add('${r.kind.name}:${r.name}');
      }
    }
    return out;
  }

  /// 全树文件夹名集合（含嵌套）。
  Future<Set<String>> allFolderNames(FavTreeController c) async {
    final names = <String>{};
    Future<void> walk(FavNode node) async {
      names.add(node.name);
      for (final k in await c.childrenOf(node.id)) {
        if (k.kind == FavKind.folder) await walk(k);
      }
    }

    for (final r in c.roots) {
      if (r.kind == FavKind.folder) await walk(r);
    }
    return names;
  }

  test('导入：两层文件夹嵌套 + 根级工程混合，结构/labels/lineGroupId 正确', () async {
    final c = await makeController();
    final before = st.undoStack.undoCount;

    final r = await importParsedResult(c, sample());

    expect(r.ok, isTrue);
    // 北京只建一次（朝阳/海淀复用）：3 文件夹、3 工程。
    expect(r.folderCount, 3);
    expect(r.projectCount, 3);
    expect(r.pointCount, 3); // 单点A、单点B、根点
    expect(r.lineCount, 2); // G001、G002（带 lineGroupId）
    // 整个导入只压一条撤销命令（内部 addFolderUndoable 的重入 execute 不压栈）。
    expect(st.undoStack.undoCount, before + 1);

    final c2 = await makeController();
    final tree = await flatTree(c2);
    // 文件夹嵌套层级：北京 → 朝阳/海淀。
    expect(tree['北京'], ['folder:朝阳', 'folder:海淀']);
    // 工程归属文件夹：朝阳工程在朝阳文件夹内，海淀工程在海淀文件夹内。
    expect(tree['朝阳'], ['project:朝阳']);
    expect(tree['海淀'], ['project:海淀']);
    // 根级工程直接落在根（不建顶层文件夹）。
    expect(tree['<root>'], ['project:根级工程']);

    // labels 数量 + lineGroupId 保留（磁盘往返）。
    final labels = await store.loadCollection(r.projectIds[0]);
    expect(labels, hasLength(3));
    expect(labels.where((l) => l.lineGroupId == 'g1'), hasLength(2));
    expect(labels.map((l) => l.name), containsAll(['G001', 'G002', '单点A']));
  });

  test('一条撤销完全回退：本次建的文件夹/工程全部消失', () async {
    final c = await makeController();
    final r = await importParsedResult(c, sample());
    expect(r.ok, isTrue);

    expect(await st.undoStack.undo(), isTrue);
    await st.refreshCollections();

    // 文件夹全部消失。
    final c2 = await makeController();
    final names = await allFolderNames(c2);
    expect(names, isNot(contains('北京')));
    expect(names, isNot(contains('朝阳')));
    expect(names, isNot(contains('海淀')));

    // 工程全部消失（collection 文件已删，读回为空）。
    for (final cid in r.projectIds) {
      expect(await store.loadCollection(cid), isEmpty);
    }

    // redo 能重新生成（对称性冒烟）。
    expect(await st.undoStack.redo(), isTrue);
    await st.refreshCollections();
    final c3 = await makeController();
    expect(await allFolderNames(c3), contains('北京'));
  });

  test('单工程导入后自动显示到地图', () async {
    final c = await makeController();
    final r = await importParsedResult(
      c,
      ImportParseResult(
        units: [
          ImportUnit(folderPath: const [], name: '单工程', labels: [pt('P1')]),
        ],
      ),
    );
    expect(r.ok, isTrue);
    expect(r.projectCount, 1);

    final meta = st.collections.firstWhere((m) => m.name == '单工程');
    expect(st.visibleCids.contains(meta.id), isTrue, reason: '只导入一个工程时应直接上图');
    expect(st.overlayLabels[meta.id], isNotNull);
  });
}
