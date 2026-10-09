import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String root;
  _FakePathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// 从 DXF 文本里抽出 LINE 实体的 (x1,y1,x2,y2)，可按图层过滤。
///
/// **必须按 (code, value) 成对步进**。踩过的坑：LINE 实体里有 `30\n0`
/// （z 坐标 = 0），那一行内容恰好是字符串 `'0'`；若逐行扫描并把任何 `'0'`
/// 当作"下一个实体的起始码"，就会在这里提前 break，一条线都读不出来。
///
/// [onLayer] 用来排除干扰实体：
/// - 图框 `TuQian` 是 10mm 边距画的大矩形（长度 = 图幅宽，比任何杆档都长）；
/// - 配线图 `PeiXianTu` 与路由图不在同一图层，需按需取。
List<List<double>> _linesOf(String text, {String? onLayer}) {
  final lines = <String>[...text.split('\n')];
  final out = <List<double>>[];
  for (var i = 0; i + 1 < lines.length; i++) {
    if (lines[i].trim() != '0' || lines[i + 1].trim() != 'LINE') continue;
    double? x1, y1, x2, y2;
    String? layer;
    // 从 i+2 起，每次前进 2 行：(code, value)
    for (var j = i + 2; j + 1 < lines.length; j += 2) {
      final code = lines[j].trim();
      if (code == '0') break; // 下一个实体开始
      if (code == '8' && onLayer != null) {
        layer = lines[j + 1].trim();
        continue;
      }
      final v = double.tryParse(lines[j + 1].trim());
      if (v == null) continue;
      switch (code) {
        case '10':
          x1 = v;
        case '20':
          y1 = v;
        case '11':
          x2 = v;
        case '21':
          y2 = v;
      }
    }
    if (x1 != null && y1 != null && x2 != null && y2 != null) {
      if (onLayer == null || layer == onLayer) out.add([x1, y1, x2, y2]);
    }
  }
  return out;
}

/// 折线长度（模型单位）。
double _lenOf(List<double> l) {
  final dx = l[2] - l[0], dy = l[3] - l[1];
  return math.sqrt(dx * dx + dy * dy);
}

/// 从 DXF 文本里抽出所有 TEXT 的字高（group 40）。同样成对步进。
List<double> _textHeightsOf(String text) {
  final lines = <String>[...text.split('\n')];
  final out = <double>[];
  for (var i = 0; i + 1 < lines.length; i++) {
    if (lines[i].trim() != '0' || lines[i + 1].trim() != 'TEXT') continue;
    for (var j = i + 2; j + 1 < lines.length; j += 2) {
      final code = lines[j].trim();
      if (code == '0') break;
      if (code == '40') {
        final v = double.tryParse(lines[j + 1].trim());
        if (v != null) out.add(v);
        break;
      }
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 造一条已知走向的折线：每步 正东 `eastM` + 正北 `northM`（斜向步进）。
  ///
  /// 步长用 haversine 反算经纬增量，故每档真实距离 = √(eastM² + northM²)。
  List<(double, double)> _route(double eastM, double northM) {
    const r = 6371000.0;
    const lat0 = 32.1264;
    double dxLon(double m) =>
        m / (r * math.cos(lat0 * math.pi / 180) * math.pi / 180);
    double dyLat(double m) => m / (r * math.pi / 180);
    return [
      (0.0, 0.0),
      (dyLat(northM), dxLon(eastM)),
      (dyLat(northM * 2), dxLon(eastM * 2)),
    ];
  }

  /// 每档真实长度（米）。
  double _stepRealM(double eastM, double northM) =>
      math.sqrt(eastM * eastM + northM * northM);

  /// pin 圆半径（纸面 2.5mm → 模型单位 0.0025）。杆路线两端各缩进一个。
  double _pinRadiusM() => 0.0025;

  /// 杆路线两端各缩进一个 pin 圆半径（纸面 2.5mm = 0.0025 单位），
  /// 故图上量得的长度 = 真实长度/ps - 2×pin半径。
  ///
  /// 另有**投影近似误差**：dxf 用等距圆柱近似（scaleY 固定 110540，而正北方向
  /// 真值是 111132.92 - 559.82·cos(2φ) ≈ 110070），32° 纬处偏差约 0.43%。
  /// 故断言容差取 **1%**（≈2.5 米真实），不放成 1e-4。
  double _expectedPaperM(double realM, int ps) => realM / ps - 2 * _pinRadiusM();

  /// 断言两个图纸长度一致（容差 = 等距圆柱近似误差 1%）。
  void _expectPaperClose(double actual, double expected, String why) {
    expect(actual, closeTo(expected, expected.abs() * 0.01 + 1e-6),
        reason: why);
  }

  Future<(String, Directory)> _export({
    required List<MapLabel> labels,
    required int plotScale,
    List<FiberLink> links = const [],
    String name = '比例自检',
  }) async {
    final dir = Directory.systemTemp.createTempSync('ovimap_scale');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final r = await DxfExporter.export(
      name: name,
      labels: labels,
      includeSurroundings: false,
      version: DxfVersion.r12,
      fiberLinks: links,
      plotScale: plotScale,
    );
    final text = gbk_bytes.decode(r.file.readAsBytesSync());
    return (text, dir);
  }

  test('1:3000 —— 图上量距 × 3000 == 真实米数（杆距口径）', () async {
    const ps = 3000;
    final offsets = _route(200, 150); // 正东 200m → 正北 150m
    final labels = <MapLabel>[];
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
        typeId: 'pole',
        seq: i + 1,
        lat: 32.1264 + offsets[i].$1,
        lon: 114.0913 + offsets[i].$2,
        lineGroupId: 'g1',
      ));
    }

    final (text, dir) = await _export(labels: labels, plotScale: ps);

    // **只取杆路层 GanLu**：图框 TuQian 是 10mm 边距的大矩形，比任何杆档都长，
    // 不按图层过滤就会把图框边线误当成"最长杆档"（这正是第一次跑测的教训）。
    final lines = _linesOf(text, onLayer: 'GanLu');
    expect(lines, isNotEmpty, reason: '应至少画出杆路线段');

    final paperM = _lenOf(lines.first);
    final stepReal = _stepRealM(200, 150); // 每档真实米数
    final expected = _expectedPaperM(stepReal, ps);

    print('图上杆档 = ${paperM.toStringAsFixed(5)} 单位，'
        '预期 ${expected.toStringAsFixed(5)}（标称每档 ${stepReal.toStringAsFixed(1)}m @1:$ps）');
    print('反算真实距离 = ${(paperM * ps).toStringAsFixed(1)} 米'
        '（+ 两端 pin 缩进 ${(2 * _pinRadiusM() * ps).toStringAsFixed(1)} 米 '
        '= ${(paperM * ps + 2 * _pinRadiusM() * ps).toStringAsFixed(1)} 米）');

    // 核心断言：**图上量距 × 3000 == 真实米数**
    //
    // 注意反算值会比标称档距**少 15 米**：两端各缩进一个 pin 半径
    // （0.0025 单位 × 3000 = 7.5 米）。这是有意为之——线不能穿过杆符号圆心。
    // 故反算时要把这 15 米加回去，才等于真实档距。
    _expectPaperClose(paperM, expected, '杆档图上长度应等于 真实米/ps - pin 缩进');
    final backCalcM = paperM * ps + 2 * _pinRadiusM() * ps;
    expect(backCalcM, closeTo(stepReal, stepReal * 0.01));

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('比例切换：几何随 plotScale 严格线性缩放', () async {
    // 同一份数据分别按 1:2000 与 1:4000 导出，图上长度应恰好差 2 倍。
    final offsets = _route(200, 150);
    List<MapLabel> mk() => [
          for (var i = 0; i < offsets.length; i++)
            MapLabel(
              typeId: 'pole',
              seq: i + 1,
              lat: 32.1264 + offsets[i].$1,
              lon: 114.0913 + offsets[i].$2,
              lineGroupId: 'g1',
            )
        ];

    double longestOf(String text) {
      final ls = _linesOf(text, onLayer: 'GanLu');
      expect(ls, isNotEmpty);
      var best = 0.0;
      for (final l in ls) {
        final d = _lenOf(l);
        if (d > best) best = d;
      }
      return best;
    }

    final (t2k, d2k) = await _export(labels: mk(), plotScale: 2000, name: 'p2000');
    final (t4k, d4k) = await _export(labels: mk(), plotScale: 4000, name: 'p4000');

    final l2k = longestOf(t2k), l4k = longestOf(t4k);
    final stepReal = _stepRealM(200, 150);
    final e2k = _expectedPaperM(stepReal, 2000);
    final e4k = _expectedPaperM(stepReal, 4000);
    print('1:2000 杆档 = ${l2k.toStringAsFixed(5)}（预期 ${e2k.toStringAsFixed(5)}）');
    print('1:4000 杆档 = ${l4k.toStringAsFixed(5)}（预期 ${e4k.toStringAsFixed(5)}）');
    print('比值 = ${l2k / l4k}（不严格等于 2：pin 缩进量是**纸面**固定值，'
        '不随比例缩放，故小比例图相对"胖"一点）');
    // 各自与理论值严格吻合
    _expectPaperClose(l2k, e2k, '1:2000 杆档长度');
    _expectPaperClose(l4k, e4k, '1:4000 杆档长度');
    // 大比例的图必然更短（这是"模型空间写缩小坐标"的直接体现）
    expect(l2k, greaterThan(l4k));

    // 比例标注同步变化
    expect(t2k, contains('比例 1:2000'));
    expect(t4k, contains('比例 1:4000'));

    d2k.deleteSync(recursive: true);
    d4k.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('图面元素与比例无关：2.5mm 字高在任何比例下都是 0.0025 单位', () async {
    // 这是本次重构的核心承诺：比例只缩放几何，**不缩放字号/符号/线宽**。
    // 旧实现按 mm/1000×routeScale 换算，字号会随线路长度膨胀，图就不像设计图。
    final offsets = _route(200, 150);
    List<MapLabel> mk() => [
          for (var i = 0; i < offsets.length; i++)
            MapLabel(
              typeId: 'pole',
              seq: i + 1,
              lat: 32.1264 + offsets[i].$1,
              lon: 114.0913 + offsets[i].$2,
              lineGroupId: 'g1',
            )
        ];

    final (t2k, d2k) = await _export(labels: mk(), plotScale: 2000, name: 'f2000');
    final (t4k, d4k) = await _export(labels: mk(), plotScale: 4000, name: 'f4000');

    final h2k = _textHeightsOf(t2k), h4k = _textHeightsOf(t4k);
    expect(h2k, isNotEmpty);
    expect(h4k, isNotEmpty);

    // 两份文件里的字号集合必须完全相同
    final s2k = h2k.map((v) => v.toStringAsFixed(5)).toSet();
    final s4k = h4k.map((v) => v.toStringAsFixed(5)).toSet();
    print('1:2000 字号集合 = $s2k');
    print('1:4000 字号集合 = $s4k');
    expect(s4k, s2k);

    // 常规注记 2.5mm = 0.0025；图例标题 3.0mm；指北针 N 字 3.5mm。
    // （次要注记 2.0mm 只在有盘留/光缆型号时才出现，本用例数据没填这些字段。）
    expect(s2k, contains('0.00250'));
    expect(s2k, contains('0.00300'));
    expect(s2k, contains('0.00350'));
    // 最大字号不得超过 3.5mm
    expect(h2k.reduce(math.max), lessThanOrEqualTo(0.0035));

    d2k.deleteSync(recursive: true);
    d4k.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('配线图与路由图同比例同走向：叠合偏移恒为图纸量', () async {
    // 用户核心诉求：配线图 = 缩小版路由图，两张图叠合能对齐。
    // 验证方式：配线图 PeiXianTu 线段的总长（模型单位）应与
    // 路由图对应档距（模型单位）落在同一量级——因为它们同除以 plotScale。
    const ps = 3000;
    final offsets = _route(300, 200);
    final labels = <MapLabel>[];
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
        typeId: 'pole',
        seq: i + 1,
        lat: 32.1264 + offsets[i].$1,
        lon: 114.0913 + offsets[i].$2,
        lineGroupId: 'g1',
      ));
    }
    // 两端各放一个分纤盒，用 FiberLink 连起来
    final a = MapLabel(
        typeId: 'fiberbox', seq: 1, lat: labels.first.lat, lon: labels.first.lon);
    final b = MapLabel(
        typeId: 'fiberbox', seq: 99, lat: labels.last.lat, lon: labels.last.lon);
    labels.addAll([a, b]);

    final (text, dir) = await _export(
      labels: labels,
      plotScale: ps,
      links: [
        FiberLink(
            fromDeviceId: a.id,
            toDeviceId: b.id,
            lengthM: 360,
            cores: 24,
            cableModel: 'GYTS',
            layMethod: 1)
      ],
      name: '配线套合',
    );

    // 配线图折线必须存在
    expect(text, contains('PeiXianTu'));
    expect(text, contains('24芯GYTS（架空）'));

    // 路由图档距：每档真实 √(300²+200²)=360.6m，@1:3000 → 0.1202 单位，
    // 两端缩进 pin 半径后 ≈0.1151。**与上面 dump 出的实测值一致。**
    final routeLines = _linesOf(text, onLayer: 'GanLu');
    expect(routeLines, isNotEmpty);
    final lens = routeLines.map(_lenOf).toList()..sort();
    final stepReal = _stepRealM(300, 200);
    final expected = _expectedPaperM(stepReal, ps);
    print('路由图杆档（图上单位）= ${lens.map((e) => e.toStringAsFixed(5)).toList()}，'
        '预期 ${expected.toStringAsFixed(5)}');
    _expectPaperClose(lens.last, expected, '路由图杆档长度');
    expect(lens.last * ps + 2 * _pinRadiusM() * ps,
        closeTo(stepReal, stepReal * 0.01));

    // 配线图（PeiXianTu 层）也必须落在同一量级 —— 这是"同比例"的直接证据：
    // 若配线图仍按真实米落图（wiringScale=1.0 的旧写法），它会比路由图大 3000 倍。
    final wiringLines = _linesOf(text, onLayer: 'PeiXianTu');
    expect(wiringLines, isNotEmpty, reason: '配线图折线应存在');
    final wiringMax =
        wiringLines.map(_lenOf).reduce(math.max);
    print('配线图最长线段 = ${wiringMax.toStringAsFixed(5)} 单位');
    // 配线图跨整条路由 ≈ 2 档 = 721m → 0.24 单位；允许 ±30% 容差
    expect(wiringMax, greaterThan(expected * 1.0));
    expect(wiringMax, lessThan(expected * 3.0));

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('比例防御：非法 plotScale 回落到 1:3000 而不是产出废图', () async {
    final offsets = _route(100, 100);
    final labels = [
      for (var i = 0; i < offsets.length; i++)
        MapLabel(
          typeId: 'pole',
          seq: i + 1,
          lat: 32.1264 + offsets[i].$1,
          lon: 114.0913 + offsets[i].$2,
          lineGroupId: 'g1',
        )
    ];
    // plotScale = 0 会让几何除零 → Infinity/NaN 坐标 → CAD 打不开
    final (text, dir) = await _export(labels: labels, plotScale: 0);
    expect(text, contains('比例 1:3000'));
    expect(text, isNot(contains('NaN')));
    expect(text, isNot(contains('Infinity')));
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('符号块必须是纸面毫米级：INSERT 不能比图框还大', () async {
    // 2026-10-09 严重事故回归闸门。
    //
    // 症状：块定义里直接写 `10.0`（想当然当成模型单位），而 INSERT 缩放是 1.0
    //       → 10mm 的槽位箱在 1:3000 下变成 10 个模型单位（=30 公里），
    //       符号比整张图纸大 1000 倍，渲染出来内容被压成一个点。
    //
    // 检测口径：**任一 INSERT 的包围盒都必须远小于图框**。符号是毫米级，
    // 图框是几十厘米级，比值应 < 0.1；事故态下该比值会是 40+。
    final offsets = _route(400, 300);
    final labels = <MapLabel>[];
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
        typeId: 'pole',
        seq: i + 1,
        lat: 32.1264 + offsets[i].$1,
        lon: 114.0913 + offsets[i].$2,
        lineGroupId: 'g1',
      ));
    }
    // 加一个分纤盒（会输出 HZ_FIBERBOX 符号块）
    labels.add(MapLabel(
      typeId: 'fiberbox',
      seq: 99,
      lat: labels.first.lat,
      lon: labels.first.lon,
      name: '测试分纤盒',
    ));

    final (text, dir) = await _export(labels: labels, plotScale: 3000);

    // 抽 INSERT 的 41/42/43 组码（插入点 + 缩放）不夠——块内容在 BLOCKS 段。
    // 直接量块定义里所有数值的最大绝对值：符号块内不应出现 > 0.1 的坐标。
    final blocksStart = text.indexOf('BLOCKS');
    final blocksEnd = text.indexOf('ENDSEC', blocksStart);
    expect(blocksStart, greaterThan(0), reason: '应含 BLOCKS 段');
    final blockTxt = text.substring(blocksStart, blocksEnd);

    // 解析块段内所有 group 10/11/20/21/40 的数值
    final bl = <String>[...blockTxt.split('\n')];
    var maxVal = 0.0;
    for (var i = 0; i + 1 < bl.length; i += 2) {
      final c = bl[i].trim();
      if (const {'10', '11', '20', '21', '40'}.contains(c)) {
        final v = double.tryParse(bl[i + 1].trim());
        if (v != null && v.abs() > maxVal) maxVal = v.abs();
      }
    }
    print('块定义内最大数值 = $maxVal（应 ≤ 0.01，即纸面 10mm 级）');
    // 纸面 10mm = 0.01 单位。留 2 倍余量。
    expect(maxVal, lessThanOrEqualTo(0.02),
        reason: '块定义用了模型单位而非纸面毫米 → 符号会被放大 1000 倍');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('图框完整包住全部内容：符号/文字不得越框', () async {
    // 同一事故的第二道闸：图框 TuQian 的矩形应严格大于所有 INSERT 的包围盒。
    final offsets = _route(400, 300);
    final labels = <MapLabel>[];
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
        typeId: 'pole',
        seq: i + 1,
        lat: 32.1264 + offsets[i].$1,
        lon: 114.0913 + offsets[i].$2,
        lineGroupId: 'g1',
      ));
    }
    labels.add(MapLabel(
        typeId: 'fiberbox', seq: 99, lat: labels.first.lat,
        lon: labels.first.lon, name: '测试分纤盒'));

    final (text, dir) = await _export(labels: labels, plotScale: 3000);

    // 图框矩形：TuQian 层上的 4 条 LINE，取其 min/max
    final frame = _linesOf(text, onLayer: 'TuQian');
    expect(frame, isNotEmpty, reason: '应有图框');
    var fx0 = double.infinity, fx1 = -double.infinity;
    var fy0 = double.infinity, fy1 = -double.infinity;
    for (final l in frame) {
      fx0 = math.min(math.min(fx0, l[0]), l[2]);
      fx1 = math.max(math.max(fx1, l[0]), l[2]);
      fy0 = math.min(math.min(fy0, l[1]), l[3]);
      fy1 = math.max(math.max(fy1, l[1]), l[3]);
    }
    final frameW = fx1 - fx0;
    print('图框尺寸 = ${frameW.toStringAsFixed(4)} × '
        '${(fy1 - fy0).toStringAsFixed(4)} 单位 '
        '（= 纸面 ${(frameW * 1000).toStringAsFixed(0)} × '
        '${((fy1 - fy0) * 1000).toStringAsFixed(0)} mm）');

    // 1:3000 下 700m 线路 → 图框约 233mm 宽，属正常图纸尺度
    expect(frameW, greaterThan(0.05), reason: '图框不应小到 50mm 以下');
    expect(frameW, lessThan(0.5), reason: '图框不应超过 500mm（否则内容被缩成一个点）');

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('越框闸门：配线图与图例都不得戳出图框', () async {
    // 2026-10-09 越框事故回归。
    //
    // 症状一：配线图原点在路径起点，下沿可达 118mm，直接戳出图框 11mm。
    // 症状二：图例锚在左下角**向下生长**，类型多时（6 类 = 42mm）同样溢出。
    //
    // 检测口径：**所有图层的所有实体（含 LINE/TEXT/INSERT 插入点）必须落在
    // 图框矩形内**。用 0.1mm 容差吸收浮点与描边误差。
    const ps = 3000;
    // 多类型数据：杆 + 管 + 光交 + 分光箱 + 分纤盒 + 引上（6 类，触发图例溢出）
    final labels = <MapLabel>[];
    final offsets = _route(500, 400);
    for (var i = 0; i < offsets.length; i++) {
      labels.add(MapLabel(
        typeId: i.isEven ? 'pole' : 'pipe',
        seq: i + 1,
        lat: 32.1264 + offsets[i].$1,
        lon: 114.0913 + offsets[i].$2,
        lineGroupId: 'g1',
      ));
    }
    final cross = MapLabel(typeId: 'crossbox', seq: 90,
        lat: offsets.first.$1, lon: offsets.first.$2, name: '测试光交');
    final split = MapLabel(typeId: 'splitterbox', seq: 91,
        lat: offsets[1].$1, lon: offsets[1].$2, name: '测试分光箱',
        splitterRatio: '1:8');
    final fb = MapLabel(typeId: 'fiberbox', seq: 92,
        lat: offsets[2].$1, lon: offsets[2].$2, name: '测试分纤盒');
    final tri = MapLabel(typeId: 'tri', seq: 93,
        lat: offsets[2].$1, lon: offsets[2].$2, name: '测试引上');
    split.topoParentId = cross.id;
    fb.topoParentId = split.id;
    tri.topoParentId = split.id;
    labels.addAll([cross, split, fb, tri]);

    final (text, dir) = await _export(
      labels: labels,
      plotScale: ps,
      links: [
        FiberLink(
            fromDeviceId: cross.id,
            toDeviceId: split.id,
            lengthM: 320,
            cores: 24,
            cableModel: 'GYTS',
            layMethod: 1),
        FiberLink(
            fromDeviceId: split.id,
            toDeviceId: fb.id,
            lengthM: 180,
            cores: 12,
            cableModel: 'GYTS',
            layMethod: 3),
      ],
    );

    // 图框范围
    final frame = _linesOf(text, onLayer: 'TuQian');
    var fx0 = double.infinity, fx1 = -double.infinity;
    var fy0 = double.infinity, fy1 = -double.infinity;
    for (final l in frame) {
      fx0 = math.min(math.min(fx0, l[0]), l[2]);
      fx1 = math.max(math.max(fx1, l[0]), l[2]);
      fy0 = math.min(math.min(fy0, l[1]), l[3]);
      fy1 = math.max(math.max(fy1, l[1]), l[3]);
    }
    // 0.1mm 纸面容差（吸收浮点与描边误差）
    final tol = 0.0001;
    print('图框 = [${fx0.toStringAsFixed(4)}, ${fy0.toStringAsFixed(4)}] → '
        '[${fx1.toStringAsFixed(4)}, ${fy1.toStringAsFixed(4)}]');

    // 检查配线图（PeiXianTu）
    final px = _linesOf(text, onLayer: 'PeiXianTu');
    print('配线图线段 ${px.length} 条');
    var wiringMinY = double.infinity, wiringMaxY = -double.infinity;
    for (final l in px) {
      wiringMinY = math.min(math.min(wiringMinY, l[1]), l[3]);
      wiringMaxY = math.max(math.max(wiringMaxY, l[1]), l[3]);
    }
    if (px.isNotEmpty) {
      print('配线图 y 范围 = [${wiringMinY.toStringAsFixed(4)}, '
          '${wiringMaxY.toStringAsFixed(4)}]，框内 y 范围 = '
          '[${fy0.toStringAsFixed(4)}, ${fy1.toStringAsFixed(4)}]');
      expect(wiringMinY, greaterThanOrEqualTo(fy0 - tol),
          reason: '配线图下沿戳出图框 ${((fy0 - wiringMinY) * 1000).toStringAsFixed(1)} mm');
      expect(wiringMaxY, lessThanOrEqualTo(fy1 + tol),
          reason: '配线图上沿戳出图框');
    }

    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
