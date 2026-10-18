import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
///
/// 注意：本测试**不依赖任何仓库外文件**。2026-10-18 曾用
/// `../user/files/upload.ovkml`（用户上传的真实文件，不在仓库里），
/// CI 里文件不存在导致 Windows/macOS 构建失败。现改用程序化生成
/// 合成大树数据（1000 文件夹 + 800 工程），完全覆盖"大树首帧只建
/// 顶层行"的验证目标。
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
    // 合成大树数据（程序化生成，不依赖外部文件）：
    // 100 顶层文件夹 × 每文件夹 9 个子文件夹 = 1000 文件夹，
    // 800 工程均匀分布在各文件夹内。节点总数 1800 > 200，
    // 触发大树默认收起路径。
    late FavTreeController c;
    await tester.runAsync(() async {
      // 1. 批量建文件夹：100 顶层 + 900 子文件夹。
      final folders = <Folder>[];
      for (var t = 0; t < 100; t++) {
        final topId = 'top_$t';
        folders.add(Folder(topId, '文件夹$t'));
        for (var s = 0; s < 9; s++) {
          folders.add(Folder('sub_${t}_$s', '子文件夹$s', topId));
        }
      }
      await store.addFolders(folders);

      // 2. 批量建工程：800 个，每工程 1 点，均匀分布在 1000 个文件夹内。
      final specs = <CollectionWrite>[];
      for (var i = 0; i < 800; i++) {
        final folderId = folders[i % folders.length].id;
        specs.add(CollectionWrite(
          name: '工程$i',
          kind: 'design',
          folderId: folderId,
          editMode: 'design',
          labels: [
            MapLabel(typeId: 'pipe', lat: 32.0, lon: 114.0, name: '杆$i'),
          ],
        ));
      }
      await store.finishCollections(specs);

      // 3. 刷新 AppState，建控制器。
      await st.refreshCollections();
      c = FavTreeController(st);
      await c.ready;
      print('合成大树完成: roots=${c.roots.length}, '
          'folders=${c.folders.length}, projects=${c.projects.length}');
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

    // 3. 首帧只应有少量行（根行 + 顶层节点），远少于全量行数。
    //    用 Text 数估算：每行约 1-2 个 Text（标题 + 计数）。
    final textCount = tester.widgetList(find.byType(Text)).length;
    print('首帧 Text 数=$textCount');
    expect(textCount, lessThan(500),
        reason: '大树首帧应只建顶层行，Text 数应远小于全量行数');

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
