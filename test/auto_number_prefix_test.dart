// 自动编号兼容存量杆号写法。
//
// 现场导入的工程杆号常见 `G1`、`G003`、`G 7`，而本软件生成的是 `G-12`。
// 旧实现只认 `前缀-数字`：导入后第一次打点会从 `G-1` 重新开始，
// 和存量杆号撞号，外业按杆号核对时直接对错杆。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_fs_cleanup.dart';

final store = LabelStore.instance;

Future<AppState> makeState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final st = AppState();
  st.setPrefsForTest(await SharedPreferences.getInstance());
  return st;
}

MapLabel named(String name) =>
    MapLabel(typeId: 'concrete', name: name, lat: 32.0, lon: 114.0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_autonum');
    store.setBaseDirForTest(dir);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    AppPaths.clearForTest();
    await deleteTempDirResilient(dir);
  });

  test('存量杆号 G1 / G003：新点接最大号 G-4', () async {
    final st = await makeState();
    st.setAutoNumber(true, 'G');
    st.labels.addAll([named('G1'), named('G003')]);

    final l = st.addLabelAtWgs(32.5, 114.5);

    expect(l.name, 'G-4', reason: '要认 G1/G003 这类写法，不能从 1 重新开始');
  });

  test('带空格 / 下划线的杆号也能接上', () async {
    final st = await makeState();
    st.setAutoNumber(true, 'G');
    st.labels.addAll([named('G 7'), named('G_12')]);

    final l = st.addLabelAtWgs(32.5, 114.5);

    expect(l.name, 'G-13');
  });

  test('不同前缀不互相污染（GK 不算进 G）', () async {
    final st = await makeState();
    st.setAutoNumber(true, 'G');
    st.labels.addAll([named('GK-9'), named('G-2')]);

    final l = st.addLabelAtWgs(32.5, 114.5);

    expect(l.name, 'G-3', reason: 'GK-9 的号码不能算到 G 前缀上');
  });

  test('本软件格式 G-12 仍然接 G-13', () async {
    final st = await makeState();
    st.setAutoNumber(true, 'G');
    st.labels.addAll([named('G-12')]);

    final l = st.addLabelAtWgs(32.5, 114.5);

    expect(l.name, 'G-13');
  });
}
