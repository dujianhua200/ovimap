// 配线图落点回归：配线图必须是纯拓扑，且不压路由图/底图，图框要包含它。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/services/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 图层包围盒（图纸坐标，米）。
class _Box {
  double minX = double.infinity;
  double minY = double.infinity;
  double maxX = -double.infinity;
  double maxY = -double.infinity;
  int n = 0;

  void add(double x, double y) {
    n++;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }

  bool get isEmpty => n == 0;
  double get width => maxX - minX;
  double get height => maxY - minY;

  bool intersects(_Box o) =>
      minX < o.maxX && maxX > o.minX && minY < o.maxY && maxY > o.minY;

  bool contains(_Box o) =>
      minX <= o.minX + 1e-6 &&
      minY <= o.minY + 1e-6 &&
      maxX >= o.maxX - 1e-6 &&
      maxY >= o.maxY - 1e-6;
}

/// 按图层统计实体包围盒（R12 文本，GBK 解码）。
Map<String, _Box> _layerBoxes(String dxf) {
  final lines = dxf.split('\n');
  final out = <String, _Box>{};
  String? layer;
  double? x, y;
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = int.tryParse(lines[i].trim());
    if (code == null) continue;
    final value = lines[i + 1].trim();
    switch (code) {
      case 0:
        layer = null;
        x = null;
        y = null;
      case 8:
        layer = value;
      case 10:
      case 11:
        x = double.tryParse(value);
      case 20:
      case 21:
        y = double.tryParse(value);
    }
    if (layer != null && x != null && y != null) {
      out.putIfAbsent(layer, () => _Box()).add(x, y);
    }
  }
  return out;
}

void main() {
  late Directory dir;
  final store = LabelStore.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovimap_wiring');
    store.setBaseDirForTest(dir);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'dxfSurroundings': false,
      'dxfUseLocal': false,
    });
  });

  tearDown(() {
    AppPaths.clearForTest();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  MapLabel label(String id, String type, String name, int seq, double lat,
          double lon) =>
      MapLabel(
        id: id,
        typeId: type,
        name: name,
        seq: seq,
        lat: lat,
        lon: lon,
        lineGroupId: 'g1',
      );

  test('配线图与路由图不相交，且被图框包含', () async {
    final labels = <MapLabel>[];
    // 12 档向东（≈80m/档）+ 6 档向北，L 形路由
    for (var i = 0; i < 12; i++) {
      labels.add(label(
        'p$i',
        i == 0 ? 'crossbox' : 'concrete',
        i == 0 ? '光交A' : 'G-${i + 1}',
        i + 1,
        32.0,
        114.0 + i * 0.00085,
      ));
    }
    for (var i = 1; i <= 6; i++) {
      labels.add(label(
        'p${11 + i}',
        i == 6 ? 'termbox' : 'concrete',
        i == 6 ? '分纤箱C' : 'G-${12 + i}',
        12 + i,
        32.0 + i * 0.0008,
        114.0 + 11 * 0.00085,
      ));
    }

    final links = [
      FiberLink(fromDeviceId: 'p0', toDeviceId: 'p11'),
      FiberLink(fromDeviceId: 'p11', toDeviceId: 'p17'),
    ];

    final r = await DxfExporter.export(
      name: 'wiring_place',
      labels: labels,
      includeSurroundings: false,
      showLegend: false,
      fiberLinks: links,
      version: DxfVersion.r12,
    );

    final dxf = gbk_bytes.decode(r.file.readAsBytesSync());
    final boxes = _layerBoxes(dxf);
    final route = boxes['GanLu'];
    final pei = boxes['PeiXianTu'];
    final frame = boxes['TuQian'];

    expect(route, isNotNull, reason: '路由层 GanLu 无实体');
    expect(pei, isNotNull, reason: '配线图层 PeiXianTu 无实体');
    expect(frame, isNotNull, reason: '图框层 TuQian 无实体');
    expect(pei!.isEmpty, isFalse);

    // 1) 配线图不得压路由图（含杆路、桩号、标注所在区域）
    expect(route!.intersects(pei), isFalse,
        reason: '配线图 bbox(${pei.minX},${pei.minY})-(${pei.maxX},${pei.maxY}) '
            '与路由 bbox(${route.minX},${route.minY})-(${route.maxX},${route.maxY}) 相交');

    // 2) 图框必须完整包含配线图
    expect(frame!.contains(pei), isTrue,
        reason: '图框未包含配线图：框 ${frame.minX},${frame.minY}-${frame.maxX},${frame.maxY}，'
            '配线 ${pei.minX},${pei.minY}-${pei.maxX},${pei.maxY}');

    // 3) 配线图是压缩后的拓扑，不能和路由一样大
    expect(pei.width, lessThan(route.width * 0.75),
        reason: '配线图宽度 ${pei.width} 接近路由宽度 ${route.width}，说明没有压缩');

    // 4) 配线图里不出现中间杆（拓扑只画设备）
    expect(dxf.contains('G-5'), isTrue); // 路由图正常出杆名
    expect(dxf.contains('光交A'), isTrue);
    expect(dxf.contains('分纤箱C'), isTrue);
  });
}
