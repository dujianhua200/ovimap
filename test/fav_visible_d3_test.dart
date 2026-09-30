import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/state/fav_tree_controller.dart';

/// D3 visible 双源统一。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;
  late LabelStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_visd3');
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

  Future<String> mkProject(String name) => store.finishCollection(
        name: name,
        kind: 'label',
        folderId: '',
        editMode: 'design',
        labels: const <MapLabel>[],
        clearDraftNow: false,
      );

  Future<List<Map<String, dynamic>>> readIndexEntries() async {
    final dir = await store.labelsDir();
    final f = File('${dir.path}/index.json');
    if (!f.existsSync()) return [];
    final d = jsonDecode(await f.readAsString());
    final List items =
        d is List ? d : ((d as Map)['items'] as List? ?? []);
    return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Map<String, dynamic> entryOf(List<Map<String, dynamic>> es, String cid) =>
      es.firstWhere((e) => e['id'] == cid);

  group('D3 visible 双源统一', () {
    test('toggleVisible 双写 index.json：隐藏写 visible=false，显示删键', () async {
      final cid = await mkProject('工程A');
      await st.refreshCollections();

      st.toggleVisible(cid); // 显示
      expect(st.visibleCids.contains(cid), isTrue);
      // fire-and-forget 的 index.json 双写落盘
      await Future<void>.delayed(const Duration(milliseconds: 100));
      var es = await readIndexEntries();
      expect(entryOf(es, cid).containsKey('visible'), isFalse);

      st.toggleVisible(cid); // 隐藏
      expect(st.visibleCids.contains(cid), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      es = await readIndexEntries();
      expect(entryOf(es, cid)['visible'], isFalse);
      expect(st.prefs.getString(AppState.prefVisible), isNot(contains(cid)));

      st.toggleVisible(cid); // 再显示：visible 键被删掉（文件干净）
      await Future<void>.delayed(const Duration(milliseconds: 100));
      es = await readIndexEntries();
      expect(entryOf(es, cid).containsKey('visible'), isFalse);
    });

    test('setVisibleBulk 双写 index.json：循环后一次写完两个', () async {
      final a = await mkProject('工程A');
      final b = await mkProject('工程B');
      await st.refreshCollections();

      await st.setVisibleBulk([a, b], true);
      await st.setVisibleBulk([a, b], false);

      final es = await readIndexEntries();
      expect(entryOf(es, a)['visible'], isFalse);
      expect(entryOf(es, b)['visible'], isFalse);
      expect(st.visibleCids, isEmpty);
      expect(st.prefs.getString(AppState.prefVisible), isEmpty);

      // 无变化时不写（prefs 保持空串，不抛错）
      await st.setVisibleBulk([a, b], false);
      expect(st.visibleCids, isEmpty);
    });

    test('applyIndexVisibilityOverride：index.json visible==false 优先剔除',
        () async {
      final a = await mkProject('工程A');
      final b = await mkProject('工程B');
      await st.refreshCollections();

      // index.json（较新的写入机制）标记 b 隐藏
      await FavTreeController.persistProjectVisible(store, b, false);
      expect(await FavTreeController.loadIndexHiddenIds(store), {b});

      // 模拟 init 读 prefs 的结果
      st.visibleCids.addAll([a, b]);
      await st.applyIndexVisibilityOverride();
      expect(st.visibleCids, {a});
    });

    test('persistProjectVisible 幂等：重复写同一状态不损坏其它字段', () async {
      final cid = await mkProject('工程A');
      await st.refreshCollections();
      await FavTreeController.persistProjectVisible(store, cid, false);
      await FavTreeController.persistProjectVisible(store, cid, false);
      final e = entryOf(await readIndexEntries(), cid);
      expect(e['visible'], isFalse);
      expect(e['name'], '工程A'); // 其它键原样保留
      await FavTreeController.persistProjectVisible(store, cid, true);
      expect(
          entryOf(await readIndexEntries(), cid).containsKey('visible'),
          isFalse);
    });
  });
}
