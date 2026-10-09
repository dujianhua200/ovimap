// 生成"信阳李庄架空光缆改造工程"真实工况 DXF 样本，供人工看图观感。
//
// 与测试夹具的区别：这条刻意贴近真实施工图况 ——
//   · 沿道路的 18 基杆路（含 3 个直角转弯 + 1 段跨越道路）
//   · 架空/管道/埋地三种敷设方式混排 + 盘留 + 光缆型号
//   · 光交 → 分光箱 → 分纤盒 三级拓扑（走地理式配线）
//   · 人工光缆 FiberLink（走直角简化配线图，与路由图同比例）
//   · 合成底图：4 级道路 + 建筑 + 地名
//
// 产出（写到仓库外的临时目录，便于直接取用）：
//   李庄架空光缆改造_1_3000.dxf
//   李庄架空光缆改造_1_10000.dxf
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/basemap.dart';
import 'package:ovimap/export/dxf.dart';
import 'package:ovimap/export/dxf_version.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 信阳李庄一带（与既有夹具同一片区域，便于对照）。
const kLat0 = 32.1264;
const kLon0 = 114.0913;

double _mPerDegLon() => 111320.0 * math.cos(kLat0 * math.pi / 180);
const _mPerDegLat = 110540.0;

double _lonOf(double eastM) => kLon0 + eastM / _mPerDegLon();
double _latOf(double northM) => kLat0 + northM / _mPerDegLat;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('生成真实工况 DXF 样本（1:3000 与 1:10000）', () async {
    final out = Directory('${Directory.current.path}/../ovimap_dxf_preview');
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
    PathProviderPlatform.instance = _PathProvider(out.path);

    // ---- 杆路：沿主干道自西向东，3 个转弯 + 1 段跨路 ----
    // 坐标单位：米（东为 +x，北为 +y）
    const waypoints = <(double, double)>[
      (0, 0),
      (120, 0),
      (120, 85), // 转弯 1：向北
      (260, 85),
      (260, -40), // 转弯 2：向南，跨过东西向道路
      (430, -40),
      (430, 60), // 转弯 3：向东北
      (560, 60),
    ];

    const gid = 'lz-杆路-01';
    final labels = <MapLabel>[];
    var seq = 1;
    for (var i = 0; i < waypoints.length - 1; i++) {
      final a = waypoints[i], b = waypoints[i + 1];
      final segLen =
          math.sqrt(math.pow(b.$1 - a.$1, 2) + math.pow(b.$2 - a.$2, 2));
      // 每 ~55m 一基杆（真实杆路档距口径）
      final n = math.max(1, (segLen / 55).round());
      for (var k = 0; k < n; k++) {
        final t = k / n;
        final x = a.$1 + (b.$1 - a.$1) * t;
        final y = a.$2 + (b.$2 - a.$2) * t;
        labels.add(MapLabel(
          typeId: 'pole',
          seq: seq++,
          lat: _latOf(y),
          lon: _lonOf(x),
          lineGroupId: gid,
          name: '杆${(seq - 1).toString().padLeft(2, '0')}',
        ));
      }
    }
    // 末端杆
    labels.add(MapLabel(
      typeId: 'pole',
      seq: seq++,
      lat: _latOf(waypoints.last.$2),
      lon: _lonOf(waypoints.last.$1),
      lineGroupId: gid,
      name: '杆${(seq - 1).toString().padLeft(2, '0')}',
    ));

    // 给几段填敷设方式 / 盘留 / 光缆型号（真实施工图要素）
    void enrich(int idx, {int kind = 1, double slack = 0, String cable = ''}) {
      final l = labels[idx];
      l.segKind = kind;
      if (slack > 0) l.slackM = slack;
      if (cable.isNotEmpty) l.segCable = cable;
    }

    enrich(0, kind: 1, cable: '架24芯GYTS');
    enrich(1, slack: 12.5);
    enrich(2, cable: '架24芯GYTS');
    enrich(3, kind: 3); // 转弯段改管道
    enrich(4, cable: '管12芯GYTS');
    enrich(5, kind: 2, slack: 8.0, cable: '埋24芯GYTS-02'); // 跨路改直埋
    enrich(6, kind: 2);
    enrich(7, cable: '埋24芯GYTS-02');
    enrich(8, kind: 1, cable: '架24芯GYTS');
    enrich(10, slack: 15.0);

    // ---- 纤设备三级拓扑（走地理式配线）----
    final cross = MapLabel(
      typeId: 'crossbox',
      seq: 90,
      lat: _latOf(0),
      lon: _lonOf(0),
      name: '李庄光交',
      holes: 48,
      usedHoles: 12,
      splitterRatio: '',
    );
    final split = MapLabel(
      typeId: 'splitterbox',
      seq: 91,
      lat: _latOf(85),
      lon: _lonOf(260),
      name: '李庄分光箱',
      splitterRatio: '1:8',
      holes: 8,
      usedHoles: 3,
      note: '利旧箱体',
    );
    final fiber1 = MapLabel(
      typeId: 'fiberbox',
      seq: 92,
      lat: _latOf(-40),
      lon: _lonOf(430),
      name: '李庄分纤盒',
      splitterRatio: '1:4',
      holes: 12,
      usedHoles: 4,
    );
    final fiber2 = MapLabel(
      typeId: 'fiberbox',
      seq: 93,
      lat: _latOf(60),
      lon: _lonOf(560),
      name: '李庄东分纤盒',
      splitterRatio: '1:4',
      holes: 12,
      usedHoles: 2,
    );
    split.topoParentId = cross.id;
    fiber1.topoParentId = split.id;
    fiber2.topoParentId = split.id;
    split.cableSpec = '架24芯GYTS';
    fiber1.cableSpec = '埋24芯GYTS-02';
    fiber2.cableSpec = '架12芯GYTS-03';
    labels.addAll([cross, split, fiber1, fiber2]);

    // ---- 人工光缆连线（走直角简化配线图，与路由图同比例）----
    // 改造态：拆 02、建 01（用到 DxfExportResult 的工程量统计）
    final links = <FiberLink>[
      FiberLink(
        fromDeviceId: cross.id,
        toDeviceId: split.id,
        cores: 24,
        cableModel: 'GYTS',
        layMethod: 1,
        lengthM: 277.0,
        reno: 1, // 新增
      ),
      FiberLink(
        fromDeviceId: split.id,
        toDeviceId: fiber1.id,
        cores: 24,
        cableModel: 'GYTS-02',
        layMethod: 3,
        lengthM: 214.6,
        reno: 2, // 拆除
      ),
      FiberLink(
        fromDeviceId: split.id,
        toDeviceId: fiber2.id,
        cores: 12,
        cableModel: 'GYTS-03',
        layMethod: 1,
        lengthM: 320.8,
      ),
    ];

    // ---- 底图（沿用合成数据，但坐标挪到本工程走廊附近）----
    List<List<double>> line(double e0, double n0, double e1, double n1,
        {int n = 6}) {
      return [
        for (var i = 0; i <= n; i++)
          [
            _latOf(n0 + (n1 - n0) * i / n),
            _lonOf(e0 + (e1 - e0) * i / n)
          ]
      ];
    }

    // 建筑：每个环是 [[lat, lon], ...]
    List<List<double>> rect(double e0, double n0, double e1, double n1) => [
          [_latOf(n0), _lonOf(e0)],
          [_latOf(n0), _lonOf(e1)],
          [_latOf(n1), _lonOf(e1)],
          [_latOf(n1), _lonOf(e0)],
        ];

    final bm = BasemapData(
      roads: [
        RoadPoly(line(-60, -40, 620, -40, n: 10), RoadGrade.trunk, '南京路'),
        RoadPoly(line(120, -120, 120, 260, n: 8), RoadGrade.primary, '文化路'),
        RoadPoly(line(260, -120, 260, 220, n: 8), RoadGrade.secondary, '浉河路'),
        RoadPoly(line(-60, 85, 620, 85, n: 10), RoadGrade.residential, '李庄街'),
        RoadPoly(line(430, -40, 430, 220, n: 6), RoadGrade.service, ''),
      ],
      buildings: [
        BuildingPoly([rect(140, 100, 200, 150)], '李庄1号楼'),
        BuildingPoly([rect(280, -30, 330, 10)], '李庄村委会'),
        BuildingPoly([rect(460, 70, 510, 110)], ''),
      ],
      places: const [
        PlaceFeature(name: '浉河区', lat: kLat0, lon: kLon0, level: PlaceLevel.city),
        PlaceFeature(name: '李庄村', lat: 32.128, lon: kLon0, level: PlaceLevel.village),
      ],
      report: const BasemapFetchReport(
        roads: DatasetReport(FetchState.ok, source: 'preview', count: 5),
        buildings: DatasetReport(FetchState.ok, source: 'preview', count: 3),
        places: DatasetReport(FetchState.ok, source: 'preview', count: 2),
      ),
    );

    // ---- 导出两份不同比例 ----
    for (final ps in const [3000, 10000]) {
      final r = await DxfExporter.export(
        name: '李庄架空光缆改造_1_$ps',
        labels: labels,
        includeSurroundings: true,
        basemap: bm,
        version: DxfVersion.r2000,
        buildingFill: true,
        fiberLinks: links,
        plotScale: ps,
        segPrefix: '',
      );
      final dest = File('${out.path}/李庄架空光缆改造_1_$ps.dxf');
      dest.writeAsBytesSync(r.file.readAsBytesSync());
      print('已导出 ${dest.path}  ${dest.lengthSync()} 字节');
      print('  warnings=${r.warnings.length} '
          '杆路新增=${r.renoNewLenM.toStringAsFixed(1)}m '
          '光缆新增=${r.fiberNewLenM.toStringAsFixed(1)}m '
          '光缆拆除=${r.fiberRemoveLenM.toStringAsFixed(1)}m');
    }
    print('点位总数：${labels.length}（杆 ${labels.where((l) => l.typeId == "pole").length} 基）');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 把导出目录指到指定的临时根目录（复用夹具里的 FakePathProvider）。
class _PathProvider extends PathProviderPlatform {
  final String root;
  _PathProvider(this.root);
  @override
  Future<String?> getExternalStoragePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}
