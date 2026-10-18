import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/import/importer.dart';
import 'package:ovimap/import/tree_import.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';
import 'package:ovimap/ui/favorites/fav_tree.dart';
import 'test_helpers.dart';

/// 导入后大树默认收起回归（2026-10-18 用户实测：导入后 3.6GB + 冻结）。
///
/// 根因：FavTree 用 SingleChildScrollView + Column 全量布局，全部文件夹
/// 默认展开，导入 1003 文件夹 / 861 工程后要同步构建 16500+ 行，
/// Widget 测试实测跑 4 分钟无输出（卡死）。
/// 修复：节点数 > 200 时默认收起全部节点，首帧只建顶层行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;
  late LabelStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_tree_collapse');
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

  testWidgets('大树导入后首帧只建顶层行，不卡死', (tester) async {
    // 注意：testWidgets 的 fake async 区不处理真实文件 IO，
    // 文件读 + 解析 + 入树必须包在 tester.runAsync 里，否则 hang。
    late FavTreeController c;
    await tester.runAsync(() async {
      final bytes = await File(
        '${Directory.current.path}/../user/files/upload.ovkml',
      ).readAsBytes();
      final parsed = Importer.parseFile('upload.ovkml', bytes)!;
      c = FavTreeController(st);
      await c.ready;
      final r = await importParsedResult(c, parsed);
      expect(r.ok, isTrue);
      expect(r.folderCount, 1003);
      expect(r.projectCount, 861);
      print('导入完成: roots=${c.roots.length}, folders=${c.folders.length}, '
          'projects=${c.projects.length}');
    });

    // 2. 泵入 FavTree：修复前这里会卡死（4 分钟无输出）。
    //    修复后首帧只建顶层行（根行 + 顶层文件夹/工程），应秒级完成。
    final sw = Stopwatch()..start();
    print('STEP 7: 开始 pumpWidget');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: ChangeNotifierProvider<FavTreeController>.value(
              value: c,
              child: FavTree(
                controller: c,
                query: '',
                onLocate: (_) async {},
                onLocateGroup: (_) async {},
                onOpenProject: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    print('STEP 8: pumpWidget 完成，开始 pump 200ms');
    await tester.pump(const Duration(milliseconds: 200));
    sw.stop();
    print('大树首帧构建: ${sw.elapsedMilliseconds}ms');

    // 3. 首帧只应有少量行（根行 + 顶层节点），远少于 16500。
    //    用 Text 数估算：每行约 1-2 个 Text（标题 + 计数）。
    final textCount = tester.widgetList(find.byType(Text)).length;
    print('首帧 Text 数=$textCount');
    expect(textCount, lessThan(500),
        reason: '大树首帧应只建顶层行，Text 数应远小于全量 16500 行');

    // 4. 首帧构建必须快（< 30 秒，实测应 < 5 秒）。
    expect(sw.elapsedMilliseconds, lessThan(30000));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('labelCache 容量上限：150 工程轮流加载，数据仍正确', () async {
    // 建 150 个小工程（每工程 1 点），逐个经 childrenOf 加载。
    // _labelCache 上限 100，超限时淘汰最旧；淘汰后重读磁盘应仍正确
    // （缓存只是加速，不影响正确性）。
    final c = FavTreeController(st);
    await c.ready;
    final cids = <String>[];
    for (var i = 0; i < 150; i++) {
      final cid = await store.finishCollection(
        name: '工程$i',
        kind: 'design',
        folderId: '',
        editMode: 'design',
        labels: [
          MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.0, name: '杆$i'),
        ],
      );
      cids.add(cid);
    }
    await st.refreshCollections();
    // 轮流加载全部 150 个工程的 children（触发缓存填满 + 淘汰）。
    for (var i = 0; i < cids.length; i++) {
      final kids = await c.childrenOf(cids[i]);
      expect(kids, hasLength(1));
      expect(kids.first.name, '杆$i');
    }
    // 再回头读前 10 个（已被淘汰的应从磁盘重读，仍正确）。
    for (var i = 0; i < 10; i++) {
      final kids = await c.childrenOf(cids[i]);
      expect(kids, hasLength(1));
      expect(kids.first.name, '杆$i');
    }
  });
}
