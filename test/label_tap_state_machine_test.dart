// 两段式点选在 MapCanvas 上的端到端行为：
// - 编辑模式点中已有草稿标签不再新增点（关键回归）；再点同一标签弹快速编辑小框。
// - 查看模式：点中只选中（onSelect），再点同一标签弹小框。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:ovimap/services/tile_cache.dart';
import 'package:ovimap/state/app_state.dart';
import 'package:ovimap/ui/map/map_canvas.dart';

void main() {
  late Directory dir;
  late AppState st;
  late MapController mc;
  late MapLabel seed;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ovimap_tap_sm');
    LabelStore.instance.setBaseDirForTest(dir);
    st = AppState();
    // 相机防抖保存会写 prefs：注入测试 prefs，避免未 init 时空指针。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    st.setPrefsForTest(await SharedPreferences.getInstance());
    mc = MapController();
    // 种子点放在初始相机中心（WGS），保证投影落在视口内。
    seed = MapLabel(
      typeId: 'concrete',
      seq: 1,
      lat: st.initLat,
      lon: st.initLon,
      lineGroupId: 'g1',
      name: '杆A',
    );
    st.labels.add(seed);
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpCanvas(
    WidgetTester tester, {
    void Function(MapLabel?, String)? onSelect,
  }) async {
    var ready = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapCanvas(
            st: st,
            controller: mc,
            baseProvider: CacheTileProvider(
              sourceId: 'qa',
              urlTemplate: 'https://tile.invalid/{z}/{x}/{y}.png',
            ),
            onSelect: onSelect,
            onMapReady: () => ready = true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(ready, isTrue, reason: '地图应就绪');
    expect(tester.takeException(), isNull);
  }

  Future<Offset> seedScreenPos(WidgetTester tester) async {
    final disp = st.toDisplay(seed.lat, seed.lon);
    final off = mc.camera.latLngToScreenOffset(LatLng(disp[0], disp[1]));
    final tl = tester.getTopLeft(find.byType(FlutterMap));
    return tl + off;
  }

  testWidgets('编辑模式：点中已有标签不新增点，再点弹快速编辑小框', (tester) async {
    st.setMode(AppMode.edit);
    await pumpCanvas(tester);
    final pos = await seedScreenPos(tester);

    // 第一次点中：只选中，不新增点、不弹窗。
    await tester.tapAt(pos);
    await tester.pump(const Duration(milliseconds: 300));
    expect(st.labels.length, 1, reason: '点中已有标签不得新增点');
    expect(
      find.byWidgetPredicate((w) => w is AlertDialog || w is Dialog),
      findsNothing,
    );

    // 第二次点中同一标签：弹快速编辑小框。
    await tester.tapAt(pos);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byWidgetPredicate((w) => w is AlertDialog || w is Dialog),
      findsOneWidget,
    );
    expect(find.text('保存'), findsOneWidget);

    // 关掉小框，点数仍为 1。
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byWidgetPredicate((w) => w is AlertDialog || w is Dialog),
      findsNothing,
    );
    expect(st.labels.length, 1);
  });

  testWidgets('查看模式：点中先选中，再点弹小框（不再直达完整框）', (tester) async {
    MapLabel? selected;
    var selectCalls = 0;
    await pumpCanvas(
      tester,
      onSelect: (l, cid) {
        selectCalls++;
        selected = l;
      },
    );
    final pos = await seedScreenPos(tester);

    await tester.tapAt(pos);
    await tester.pump(const Duration(milliseconds: 300));
    expect(selectCalls, 1);
    expect(selected?.id, seed.id);
    expect(
      find.byWidgetPredicate((w) => w is AlertDialog || w is Dialog),
      findsNothing,
      reason: '查看模式第一次点中只选中，不弹窗',
    );

    await tester.tapAt(pos);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byWidgetPredicate((w) => w is AlertDialog || w is Dialog),
      findsOneWidget,
    );
    expect(find.text('保存'), findsOneWidget);
  });
}
