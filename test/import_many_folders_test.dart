import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/import/import_model.dart';
import 'package:ovimap/import/kml_parser.dart';
import 'package:ovimap/import/tree_import.dart';
import 'package:ovimap/models/fav_node.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';
import 'test_helpers.dart';

/// ovkml 导入卡死回归（2026-10-15 用户反馈：ovkml 约 18000 点，导入卡死、
/// 内存+CPU 爆满）：
/// - 根因 1：逐个建文件夹/工程，每次全量读+写 folders.json / index.json，
///   O(F²)/O(P²)——1800 文件夹实测超时 30 秒；
/// - 根因 2：KML 解析 description 用 List.contains 去重 O(n²)，
///   且 join 出巨型无用字符串（18000 点单 Folder 达 2.4MB，无消费方）。
/// 修复：文件夹/工程批量写（每批一次索引读写）+ description 用 Set 去重并截断。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;
  late LabelStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_import_many');
    LabelStore.instance.setBaseDirForTest(tmp);
    SharedPreferences.setMockInitialValues({});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
    store = st.store;
    await st.refreshCollections();
  });

  tearDown(() async {
    await deleteTempDir(tmp);
  });

  Future<FavTreeController> makeController() async {
    final c = FavTreeController(st);
    await c.ready;
    return c;
  }

  MapLabel pt(String name, {double lat = 32.0, double lon = 114.0}) =>
      MapLabel(typeId: 'pipe', lat: lat, lon: lon, name: name);

  /// [folders] 个文件夹 × 每夹 [pts] 个点（每夹一个工程）。
  ImportParseResult manyFolders(int folders, int pts) => ImportParseResult(
    units: [
      for (var f = 0; f < folders; f++)
        ImportUnit(
          folderPath: ['夹$f'],
          name: '夹$f',
          labels: [
            for (var i = 0; i < pts; i++)
              pt('杆$f-$i', lat: 32.0 + f * 0.001 + i * 0.00001),
          ],
        ),
    ],
  );

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

  test('200 文件夹 × 5 点批量导入：结构正确、一条撤销、撤销后全消失', () async {
    final c = await makeController();
    final before = st.undoStack.undoCount;

    final r = await importParsedResult(c, manyFolders(200, 5));
    expect(r.ok, isTrue);
    expect(r.folderCount, 200);
    expect(r.projectCount, 200);
    expect(r.pointCount, 1000);
    expect(st.undoStack.undoCount, before + 1);

    // 磁盘往返：抽查一个工程的 labels。
    final labels = await store.loadCollection(r.projectIds[0]);
    expect(labels, hasLength(5));

    // 撤销：文件夹/工程全部消失。
    expect(await st.undoStack.undo(), isTrue);
    await st.refreshCollections();
    final c2 = await makeController();
    final names = await allFolderNames(c2);
    expect(names, isNot(contains('夹0')));
    expect(names, isNot(contains('夹199')));
    for (final cid in r.projectIds) {
      expect(await store.loadCollection(cid), isEmpty);
    }

    // redo 重新生成。
    expect(await st.undoStack.redo(), isTrue);
    await st.refreshCollections();
    final c3 = await makeController();
    expect(await allFolderNames(c3), contains('夹0'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('嵌套文件夹：父先于子建，工程落最深层', () async {
    final c = await makeController();
    final r = await importParsedResult(
      c,
      ImportParseResult(units: [
        ImportUnit(
          folderPath: const ['乡镇', '村', '杆路'],
          name: '杆路',
          labels: [pt('杆1')],
        ),
        ImportUnit(
          folderPath: const ['乡镇', '村', '光缆'],
          name: '光缆',
          labels: [pt('缆1')],
        ),
      ]),
    );
    expect(r.ok, isTrue);
    expect(r.folderCount, 4); // 乡镇、村、杆路、光缆（村复用一次）
    expect(r.projectCount, 2);

    final c2 = await makeController();
    final names = await allFolderNames(c2);
    expect(names, containsAll(['乡镇', '村', '杆路', '光缆']));
    // 工程归属：查索引的 folder（杆路工程→杆路文件夹，光缆工程→光缆文件夹）。
    final idx = await store.loadIndex();
    final byId = {for (final m in idx) m.id: m};
    final folders = await store.loadFolders();
    final folderIdOf = {for (final f in folders) f.name: f.id};
    expect(byId[r.projectIds[0]]?.folder, folderIdOf['杆路']);
    expect(byId[r.projectIds[1]]?.folder, folderIdOf['光缆']);
  });

  test('KML 解析：万级唯一描述去重不爆炸、描述截断', () async {
    final sb = StringBuffer()
      ..writeln('<?xml version="1.0"?><kml><Document><Folder><name>全部</name>');
    for (var n = 0; n < 2000; n++) {
      sb.writeln(
        '<Placemark><name>杆$n</name>'
        '<description>唯一描述$n ${'x' * 200}</description>'
        '<Point><coordinates>${114.0 + n * 0.00001},${32.0 + n * 0.00001}</coordinates></Point></Placemark>',
      );
    }
    sb.writeln('</Folder></Document></kml>');
    final r = KmlParser.parse(sb.toString());
    expect(r.labelCount, 2000);
    // 截断：8000 rune 上限（2000 条 × 200+ 字若不截断会 join 出 400KB+）。
    final desc = r.units.single.description;
    expect(desc, isNotNull);
    expect(desc!.runes.length, lessThanOrEqualTo(8000));
    expect(desc, contains('唯一描述0'));
  });

  test('store 批量：addFolders/deleteFolders/deleteCollections 语义', () async {
    // 建：父 + 子（批量一次写盘）。
    final created = await store.addFolders([
      Folder('f1', '父', ''),
      Folder('f2', '子', 'f1'),
    ]);
    expect(created.map((f) => f.id), ['f1', 'f2']);
    expect((await store.loadFolders()).map((f) => f.id),
        containsAll(['f1', 'f2']));

    // 空名归一为“文件夹”（与 addFolder 一致）。
    final empty = await store.addFolders([Folder('f3', '   ', '')]);
    expect(empty.single.name, '文件夹');

    // 工程进子文件夹，再批量删子文件夹：工程上移到父级（与 deleteFolder 同语义）。
    final cid = await store.finishCollection(
      name: '工程1',
      kind: 'design',
      folderId: 'f2',
      editMode: 'design',
      labels: [pt('杆1')],
    );
    final (doomed, moved) = await store.deleteFolders(['f2']);
    expect(doomed, 1);
    expect(moved, 1);
    final idx = await store.loadIndex();
    expect(idx.singleWhere((m) => m.id == cid).folder, 'f1');

    // 批量删工程：索引 + 文件一起消失。
    await store.deleteCollections([cid]);
    expect(await store.loadCollection(cid), isEmpty);
    expect((await store.loadIndex()).where((m) => m.id == cid), isEmpty);
  });
}
