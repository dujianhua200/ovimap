import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/map/map_canvas.dart' show withoutHiddenLabels;

/// D2 mark 级地图显隐。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState st;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ovimap_markvisd2');
    LabelStore.instance.setBaseDirForTest(tmp);
    SharedPreferences.setMockInitialValues({});
    st = AppState();
    st.setPrefsForTest(await SharedPreferences.getInstance());
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  MapLabel mk(String name, {String? id}) {
    final l = MapLabel(
        typeId: 'concrete', lat: 31.0, lon: 121.0, name: name);
    if (id != null) l.id = id;
    return l;
  }

  group('D2 mark 级地图显隐', () {
    test('withoutHiddenLabels：按 id 过滤，保序、不改原列表', () {
      final a = mk('A', id: 'la');
      final b = mk('B', id: 'lb');
      final c = mk('C', id: 'lc');
      final src = [a, b, c];
      final out = withoutHiddenLabels(src, {'lb'});
      expect(out.map((e) => e.id), ['la', 'lc']);
      expect(src, hasLength(3)); // 原列表不动
      expect(withoutHiddenLabels(src, const {}), hasLength(3));
      expect(withoutHiddenLabels(src, {'la', 'lb', 'lc'}), isEmpty);
    });

    test('setLabelHidden：prefs 逗号分隔持久化 + 幂等 + notify', () async {
      var notified = 0;
      st.addListener(() => notified++);
      st.setLabelHidden('lid1', true);
      expect(st.hiddenLabelIds, {'lid1'});
      expect(st.prefs.getString(AppState.prefHiddenLabelIds), 'lid1');
      expect(notified, 1);

      st.setLabelHidden('lid2', true);
      expect(st.prefs.getString(AppState.prefHiddenLabelIds), 'lid1,lid2');

      st.setLabelHidden('lid1', true); // 重复隐藏：无变化、不 notify
      expect(notified, 2);

      st.setLabelHidden('lid1', false);
      expect(st.hiddenLabelIds, {'lid2'});
      expect(st.prefs.getString(AppState.prefHiddenLabelIds), 'lid2');
      expect(notified, 3);
    });
  });

}
