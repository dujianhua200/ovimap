import 'dart:io';
import 'dart:math' as math;

import 'package:gbk_codec/gbk_codec.dart';

import '../geo/geo_util.dart';
import '../models/fiber_link.dart';
import '../models/reno_state.dart';
import '../models/label_type.dart';
import '../models/map_label.dart';
import '../services/store.dart';
import 'basemap.dart';
import 'dxf_layers.dart';
import 'dxf_validate.dart';
import 'dxf_version.dart';
import 'local_basemap.dart';
import 'road_junction.dart';
import 'topo.dart';
import 'wiring_diagram.dart';

/// DXF 导出结果：文件 + 非致命警告 + 底图抓取三态报告。
class DxfExportResult {
  final File file;
  final List<String> warnings;
  final BasemapFetchReport? report;

  /// 改造工程量统计（米）：杆路新增/拆除、人工光缆新增/拆除。
  final double renoNewLenM;
  final double renoRemoveLenM;
  final double fiberNewLenM;
  final double fiberRemoveLenM;

  DxfExportResult(this.file, this.warnings,
      [this.report,
      this.renoNewLenM = 0,
      this.renoRemoveLenM = 0,
      this.fiberNewLenM = 0,
      this.fiberRemoveLenM = 0]);
}

/// 可累加的包围盒（底图渲染时同步扩展图框范围）。
class _Ext {
  double minX;
  double minY;
  double maxX;
  double maxY;
  _Ext(this.minX, this.minY, this.maxX, this.maxY);
  void add(double x, double y) {
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
}

/// DXF 句柄分配器（仅 R2000 使用）。句柄为十六进制字符串、全局唯一、递增。
/// 起始值 `0x30`（48）；模块空间块固定占 `1F`（31，小于起始值，不冲突）。
class _H {
  int _v;
  _H([int start = 0x30]) : _v = start;
  String next() {
    final r = _v;
    _v++;
    return r.toRadixString(16).toUpperCase();
  }

  /// 下一个（尚未使用的）句柄值；用于 `$HANDSEED`（必须大于所有已用句柄）。
  int get nextValue => _v;
}

/// 实体写出上下文：把「输出缓冲 + 版本 + 句柄分配器」绑在一起，
/// 使 R12（无句柄/无子类标记）与 R2000（句柄 + `100 AcDb*` 子类标记）**共用同一套
/// 绘制函数**，仅在 [ent] 处按版本分叉，避免两套渲染逻辑漂移。
///
/// **句柄分配器在所有缓冲间共享**（主实体段与底图文字缓冲用同一个 [_H]），
/// 否则会出现重复句柄（非法文件）。
class _Ctx {
  final StringBuffer sb;
  final DxfVersion v;
  final _H h;
  _Ctx(this.sb, this.v, this.h);

  bool get r2000 => v == DxfVersion.r2000;

  /// 实体起始：写类型名 + 图层；R2000 追加句柄 `5`、属主 `330`、子类标记 `100`。
  void ent(String type, String layer, String sub) {
    sb.write('0\n$type\n');
    if (r2000) {
      sb.write('5\n${h.next()}\n330\n1F\n100\nAcDbEntity\n8\n$layer\n100\n$sub\n');
    } else {
      sb.write('8\n$layer\n');
    }
  }
}

/// DXF 导出（默认 **R12/AC1009**，可选 **R2000/AC1015**——两者均**结构合法**，
/// 以真实解析器 ezdxf 严格打开为准）。
///
/// ## 坐标与比例（2026-10-09 重构：单一比例体系）
///
/// **模型空间就是"缩小后的图纸"**：1 DXF 单位 = 1 纸面毫米 @ 出图比例。
/// 设出图比例 `plotScale`（如 3000 = 1:3000），则
/// - **几何坐标** = 真实米 ÷ `plotScale`。50m 杆档 → 0.0167 单位（=16.7mm 纸面）。
/// - **图面元素**（字高/线宽/符号/偏移）= 纸面毫米 ÷ 1000 = 毫米/1000 单位。
///   即 2.5mm 字高 → 0.0025 单位。**与 `plotScale` 无关**。
///
/// **为什么必须这样**：此前几何写 1:1 真实米、字号却按 `_mmOf(mm, routeScale)`
/// = `mm/1000 × 自动挑的 1:1000~1:10000` 换算 —— **两套比例互相打架**。
/// 后果：线路一长，自动挑的比例就跳档，字号跟着从 2.5mm 膨胀到 25mm，
/// 图永远"不像正规设计图"；且配线图与路由图无法套合。
/// 现在比例是**用户显式指定的单一值**，几何与图面元素同源同尺，
/// 路由图与配线图叠合能严格对齐，符合设计院出图要求。
///
/// - **版本分支**收敛到 3 处：①图层表（R2000 写 `370`/`420`，R12 只写 `62`/`6`）；
///   ②多段线（R2000=`LWPOLYLINE`，R12=经典 `POLYLINE/VERTEX/SEQEND`）；
///   ③建筑填充（R2000=`HATCH`，R12=`SOLID` 三角近似）。**其余绘制逻辑完全共用**。
/// - **R2000 合法结构**：完整 HEADER（`$ACADVER/$HANDSEED/$EXTMIN/$EXTMAX/...`）+
///   CLASSES 段 + TABLES/BLOCKS 记录句柄 + 每个实体句柄(5) + `100 AcDb*` 子类标记 +
///   OBJECTS 段。**导出前后由 [DxfStructureValidator] 强校验**，校验不过即抛错，
///   绝不产出「打不开」的文件。
class DxfExporter {
  DxfExporter._();

  /// 默认出图比例（1:3000，通信线路路由图常用档）。
  static const int defaultPlotScale = 3000;

  /// 坐标格式化精度：**5 位小数**。1:3000 下 1 单位 = 1mm，
  /// 0.001 单位 = 0.001mm 纸面；3 位小数会把 16.7mm 的杆档压成 16.500，量距对不上。
  static String _fmt(double v) => v.toStringAsFixed(5);

  /// CLASSES 段（R2000）：仅声明 HATCH（实体填充）类，供读取器识别。
  static const String _classesSection =
      '0\nSECTION\n2\nCLASSES\n'
      '0\nCLASS\n1\nHATCH\n2\nAcDbHatch\n3\nObjectDBX Classes\n'
      '90\n0\n280\n0\n281\n0\n'
      '0\nENDSEC\n';

  static Future<DxfExportResult> export({
    required String name,
    required List<MapLabel> labels,
    bool includeLabelSymbols = true,
    double corridorWidth = 0, // 0=单线，>0=管廊双线宽度（米）
    bool includeSurroundings = false,
    bool showStakes = true, // 杆路里程桩号（K0+000）
    bool showLegend = true, // 图例栏自动生成
    bool completionRed = false, // 竣工图红色描边
    bool straightenedWiring = false, // 附加拉直沿线配线图（长杆路）
    // —— 本次新增（均带默认值，旧调用点无需修改）——
    DxfVersion version = DxfVersion.r12, // 默认 R12（已用 ezdxf 严格打开验证）
    double rangeM = 50, // 底图范围（米）：默认沿线 50（UI 传值优先）
    bool layerRoads = true,
    bool layerBuildingOutline = true,
    bool buildingFill = false, // 建筑填充（默认关；true 时 R2000=HATCH / R12=SOLID）
    bool showMinorRoadNames = false, // service/other 也标路名（默认只标主干道以上）
    bool layerPlaces = true,
    bool placesTdtFallback = true, // 地名兜底（高德优先，回落天地图）
    bool useOnlineBuildings = true, // 在线建筑抓取：关则只用离线兜底包（避免重复）
    bool useBuildingFallback = true, // 建筑兜底包：关则不用离线建筑包
    String tdtKey = '',
    String amapKey = '', // 高德 Web 服务 key（有则优先用于地名兜底）
    String overpassEndpoints = '', // 自定义 Overpass 端点（优先于内置；空=用内置）
    bool convertGcj = true, // 高德/天地图检索 POI 为 GCJ-02，默认纠偏为 WGS84
    bool refreshBasemap = false, // 刷新底图（忽略缓存重新抓取）
    BasemapData? basemap, // 已取好的底图（测试注入 / 复用）
    BasemapData? localBasemap, // 导入的本地开源矢量底图（离线优先）
    int localBasemapFeatureCap =
        GeoJsonImporter.defaultFeatureCap, // 本地底图要素数上限（防御性兜底）
    String segPrefix = '', // 段标前缀（如 埋／架）：空串=仅数字；透传自 AppState.segPrefix
    List<FiberLink> fiberLinks = const [], // 人工光缆拓扑连线（配线图用）
    int plotScale = defaultPlotScale, // 出图比例分母（3000 = 1:3000）
  }) async {
    final warnings = <String>[];
    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}.dxf');

    if (labels.isEmpty) throw Exception('杆路为空');
    // 比例防御：0/负数会让几何除零产出非法 DXF，此处夹到合理区间。
    final ps = plotScale < 10 ? defaultPlotScale : plotScale;

    final sb = StringBuffer();
    final h = _H();
    final c = _Ctx(sb, version, h);

    // DXF 头：声明 GBK 代码页（两版本一致），AutoCAD 中文版按此读取文字不乱码。
    // R2000 需完整 HEADER+`$HANDSEED`+范围变量；`$HANDSEED` 与图幅范围用占位符，
    // 待实体写完后回填（句柄分配器此刻才知道最终值）。
    if (version == DxfVersion.r2000) {
      sb.write('0\nSECTION\n2\nHEADER\n');
      sb.write('9\n\$ACADVER\n1\nAC1015\n');
      sb.write('9\n\$DWGCODEPAGE\n3\nANSI_936\n');
      sb.write('9\n\$INSBASE\n10\n0.000\n20\n0.000\n30\n0.000\n');
      sb.write('9\n\$LIMMIN\n10\n@@EXTMINX@@\n20\n@@EXTMINY@@\n30\n0.000\n');
      sb.write('9\n\$LIMMAX\n10\n@@EXTMAXX@@\n20\n@@EXTMAXY@@\n30\n0.000\n');
      sb.write('9\n\$EXTMIN\n10\n@@EXTMINX@@\n20\n@@EXTMINY@@\n30\n0.000\n');
      sb.write('9\n\$EXTMAX\n10\n@@EXTMAXX@@\n20\n@@EXTMAXY@@\n30\n0.000\n');
      sb.write('9\n\$HANDSEED\n5\n@@HANDSEED@@\n');
      sb.write('0\nENDSEC\n');
      sb.write(_classesSection);
    } else {
      sb.write('0\nSECTION\n2\nHEADER\n');
      sb.write('9\n\$DWGCODEPAGE\n3\nANSI_936\n');
      sb.write('9\n\$ACADVER\n1\nAC1009\n');
      sb.write('0\nENDSEC\n');
    }

    // 表（图层 + 文字样式）：R2000 写记录句柄与子类标记，R12 维持原样。
    _appendTables(c, version, completionRed);

    // 符号块定义：INSERT 引用，CAD 中可整体移动/复制/编辑（对齐图例）。
    _appendBlocksSection(c, version);

    // 实体段
    sb.write('0\nSECTION\n2\nENTITIES\n');

    // 本地投影基准点（第一个点）
    final baseLon = labels.first.lon;
    final baseLat = labels.first.lat;
    // 关键：**几何按出图比例缩小**。1:3000 时 1 度经差 ≈ 3.3e-5 单位。
    // 此前这里是 1:1 真实米（111320），是"图不像设计图"的根因。
    final scaleX = 111320.0 * math.cos(baseLat * math.pi / 180) / ps;
    final scaleY = 110540.0 / ps;

    // 实体包围盒（米，本地坐标）：用于图签/指北针定位，随周边矢量扩展
    var extMinX = 0.0, extMinY = 0.0, extMaxX = 0.0, extMaxY = 0.0;
    for (final l in labels) {
      final x = (l.lon - baseLon) * scaleX;
      final y = (l.lat - baseLat) * scaleY;
      if (x < extMinX) extMinX = x;
      if (x > extMaxX) extMaxX = x;
      if (y < extMinY) extMinY = y;
      if (y > extMaxY) extMaxY = y;
    }
    // 线路-only 包络（改造注记定位用，不被底图外扩污染）
    final routeMinY = extMinY;
    final routeMaxX = extMaxX;

    // 改造工程量：新增/拆除长度分别统计（米），原有不计入
    var renoNewLenM = 0.0;
    var renoRemoveLenM = 0.0;
    // 人工光缆改造工程量（配线图连线）
    var fiberNewLenM = 0.0;
    var fiberRemoveLenM = 0.0;
    // 桩号跨线组连续累计：续画链/分支链不再从 K0+000 重新归零，
    // 全线桩号沿链输出顺序一杆接一杆递增（与竣工里程口径一致）。
    var globalCum = 0.0;

    // 出图比例：**用户显式指定**（1:1000 ~ 1:10000），不再自动挑档。
    // 自动挑档（_pickScale）是"两套比例打架"的根源：线路一长比例就跳，
    // 字号跟着膨胀，图永远不像正规设计图。详见类文档。
    final plotLabel = '1:$ps';
    // 图面元素一律按**纸面毫米**换算（与 ps 无关）：
    // 常规注记 2.5mm（宋体）、次要注记 2.0mm、pin 圆内字 = 圆半径。
    final subFontM = _mm(2.0);
    final labelFontM = _mm(2.5);
    final noteFontM = _mm(2.0);
    final pinFontM = _pinRadius();

    // 周边矢量（底图）：**必须先于业务实体写出**。
    // DXF 中「后画者在上层」（见 _appendBasemap 内注释），故底图（含建筑填充 HATCH/SOLID）
    // 必须先画，业务层（杆路/配线/桩号/标签）后画，才能保证业务层最终置顶、
    // 不被底图填充盖住（设计 §P0-5 业务层置顶；A6 绘制顺序）。
    // 数据来源优先级：导入的本地开源矢量（离线）> 注入/缓存/网络抓取。
    BasemapFetchReport? report;
    if (includeSurroundings) {
      final BasemapData bm;
      if (localBasemap != null) {
        // 本地底图也尊重「范围档位」：裁到线路外扩 bbox，做到「只导出范围内」。
        // **裁剪结果为空时必须就用空底图**（`bm = cropped`）——**绝不回退全量**。
        // 旧实现「裁剪为空则回退全量」是用户每次导出 ≈50MB 的根因：线路一旦落在
        // 底图数据空白处（如罗山/光山/新县农村），裁剪为空 → 回退 → 整个信阳
        // 4.4 万要素全写进 DXF。此处改为「空就是空 + 明确中文提示」，绝不兜底全量。
        final bbox = BasemapFetcher.boundsOf(labels, rangeM);
        var cropped = GeoJsonImporter.cropTo(
          localBasemap,
          bbox,
          toleranceM: rangeM * 0.1, // 框边界适度外扩，避免路口被切断得太碎
        );
        // R3 防御性上限：进入渲染前兜底截断，防病态巨型文件（详见 capFeatures 文档）。
        cropped = GeoJsonImporter.capFeatures(
          cropped,
          routePts: [
            for (final l in labels) [l.lat, l.lon]
          ],
          cap: localBasemapFeatureCap,
          warnings: warnings,
        );
        final empty = cropped.roads.isEmpty &&
            cropped.buildings.isEmpty &&
            cropped.places.isEmpty;
        if (empty) {
          warnings.add(
              '本地底图：线路外扩 ${rangeM.round()} 米范围内无底图数据，本次未使用底图'
              '（可增大范围档位，或检查该区域底图数据覆盖）');
        }
        bm = cropped;
      } else if (basemap != null) {
        bm = basemap;
      } else {
        bm = await BasemapFetcher.fetchFor(
          labels,
          rangeM: rangeM,
          tdtKey: tdtKey,
          amapKey: amapKey,
          overpassEndpoints: overpassEndpoints,
          useTdt: placesTdtFallback,
          convertGcj: convertGcj,
          refresh: refreshBasemap,
          useOnlineBuildings: useOnlineBuildings,
          useBuildingFallback: useBuildingFallback,
        );
      }
      report = bm.report;
      warnings.addAll(bm.report.toWarnings());
      // 本地底图的文字缓冲与主实体共用同一句柄分配器（见 _Ctx 文档）。
      final ext = _appendBasemap(
        c,
        bm,
        version,
        baseLon: baseLon,
        baseLat: baseLat,
        scaleX: scaleX,
        scaleY: scaleY,
        ps: ps,
        layerRoads: layerRoads,
        layerBuildingOutline: layerBuildingOutline,
        buildingFill: buildingFill,
        showMinorRoadNames: showMinorRoadNames,
        layerPlaces: layerPlaces,
      );
      if (ext != null) {
        if (ext[0] < extMinX) extMinX = ext[0];
        if (ext[1] < extMinY) extMinY = ext[1];
        if (ext[2] > extMaxX) extMaxX = ext[2];
        if (ext[3] > extMaxY) extMaxY = ext[3];
      }
    }

    // 杆路输出（统一链口径）：箱体/文字插在两杆之间不再剪断杆路；
    // 管廊模式 = 整链一条闭合偏移多段线（转角自然对接，不再逐段封口出头）；
    // 同时累计里程输出桩号（ZhuangHao 层，K0+000 格式），段上标注盘留与光缆型号。
    for (final chain in buildLabelChains(labels)) {
      if (chain.length < 2) continue;
      final cart = [
        for (final l in chain)
          [(l.lon - baseLon) * scaleX, (l.lat - baseLat) * scaleY]
      ];
      if (corridorWidth > 0) {
        _appendCorridor(c, cart, _geo(corridorWidth, ps), version);
      }

      var chainCum = globalCum;
      // pin 类标签的圆半径：线只连接到圆边，不穿过圆心
      final pinR = _pinRadius();
      for (var i = 1; i < chain.length; i++) {
        final a = chain[i - 1];
        final b = chain[i];
        // 改造三态分层：原有=GanLu，新增=GanLuNew（红实线），拆除=GanLuRemove（虚线）
        final ganLayer = b.reno == RenoState.added
            ? 'GanLuNew'
            : b.reno == RenoState.removed
                ? 'GanLuRemove'
                : 'GanLu';
        // 线段两端缩进 pin 圆半径，避免穿过圆形标签
        final x1 = cart[i - 1][0], y1 = cart[i - 1][1];
        final x2 = cart[i][0], y2 = cart[i][1];
        final dx = x2 - x1, dy = y2 - y1;
        final len = math.sqrt(dx * dx + dy * dy);
        if (len > pinR * 2) {
          final ux = dx / len, uy = dy / len;
          _appendLine(c, ganLayer, x1 + ux * pinR, y1 + uy * pinR,
              x2 - ux * pinR, y2 - uy * pinR);
        } else {
          // 线段太短，直接画（避免负长度）
          _appendLine(c, ganLayer, x1, y1, x2, y2);
        }

        final mx = (cart[i - 1][0] + cart[i][0]) / 2;
        final my = (cart[i - 1][1] + cart[i][1]) / 2;
        var angle = math.atan2(cart[i][1] - cart[i - 1][1],
                cart[i][0] - cart[i - 1][0]) *
            180 /
            math.pi;
        if (angle > 90 || angle < -90) angle += 180;
        final segmentDistance =
            b.distanceM ?? _haversine(a.lat, a.lon, b.lat, b.lon);
        // 改造工程量统计：新增/拆除分别累计，原有不计入
        if (b.reno == RenoState.added) {
          renoNewLenM += segmentDistance;
        } else if (b.reno == RenoState.removed) {
          renoRemoveLenM += segmentDistance;
        }
        chainCum += segmentDistance;
        final segText = GeoUtil.segTextFor(b, _formatDistNoUnit(segmentDistance),
            prefix: segPrefix);
        // 宋体（STYLE 表里注册的是 SimSun）；字高与 pin 圆同步（= 圆半径）。
        // 偏移一律**纸面毫米**：线上 1.2mm、盘留行下方 3.4mm、逐行递减 2.6mm。
        _text(c, 'JuLi', mx, my + _mm(1.2), pinFontM, segText,
            angle: angle, style: true);
        // 盘留标注（段下方第一行）
        var extraY = my - _mm(3.4);
        if (b.slackM > 0) {
          _text(c, 'JuLi', mx, extraY, subFontM, '盘留${_formatSlack(b.slackM)}m',
              angle: angle, style: true);
          extraY -= _mm(2.6);
        }
        // 本段光缆型号（再下一行）
        if (b.segCable.trim().isNotEmpty) {
          _text(c, 'JuLi', mx, extraY, subFontM, b.segCable.trim(),
              angle: angle, style: true);
        }
        // 桩号：每杆位置标 K+里程（跨链连续；段距优先用人工确认值）
        if (showStakes) {
          if (i == 1) _appendStake(c, cart[0][0], cart[0][1], globalCum);
          _appendStake(c, cart[i][0], cart[i][1], chainCum);
        }
      }
      globalCum = chainCum;
    }

    // 拓扑存在性提前判定：有拓扑时箱体文字改由地理式配线（标签牌）输出，避免重复
    var hasTopo = false;
    for (final l in labels) {
      if (l.topoParentId.isNotEmpty) {
        hasTopo = true;
        break;
      }
    }

    // 标签符号按图例转成 CAD 符号块（INSERT 引用，可在 CAD 中整体编辑）。
    // 轨迹/无标签点不输出符号。
    if (includeLabelSymbols) {
      // 符号块定义基准 = **纸面毫米**（见 _appendBlocksSection），插入缩放固定 1.0。
      // 旧实现 symScale = routeScale/1000 让符号随比例膨胀，同样是病态根源。
      const symScale = 1.0;
      final offUpM = _mm(3.0); // 名称在符号上方 3mm
      final offDownM = _mm(4.0); // 孔数/附加在下方 4mm
      final offNoteM = _mm(6.0); // 备注 6mm
      final offPhotoM = _mm(8.0); // 照片数 8mm
      final holeDotsUpM = _mm(5.5); // 芯线占用点 5.5mm
      for (final l in labels) {
        if (l.typeId == 'track' || l.typeId == 'none') continue;
        final x = (l.lon - baseLon) * scaleX;
        final y = (l.lat - baseLat) * scaleY;
        final lt = l.type;
        final disp = l.name.trim().isNotEmpty ? l.name.trim() : lt.symbol;
        if (l.typeId == 'text') {
          if (disp.isNotEmpty) {
            _text(c, 'BiaoQian', x, y, labelFontM, disp, style: true);
          }
          continue;
        }
        String block;
        if (lt.isOval) {
          block = 'HZ_OVAL';
        } else if (lt.isBox) {
          // 分纤盒（纤）：用正规槽位箱符号（10×4.4），2026-10-08 用户要求
          // 兜底：箱体形状且非分光器/光交/ONU/机房/基站，一律按槽位箱画
          final isFb = l.typeId == 'fiberbox' ||
              l.typeId == 'fdcab' ||
              l.typeId == 'termbox' ||
              l.name.contains('分纤') ||
              (lt.isBox &&
                  l.typeId != 'splitterbox' &&
                  l.typeId != 'crossbox' &&
                  l.typeId != 'onubox' &&
                  l.typeId != 'room' &&
                  l.typeId != 'bts');
          block = isFb ? 'HZ_FIBERBOX' : 'HZ_BOX';
        } else if (lt.isTri) {
          block = 'HZ_TRI';
        } else {
          block = 'HZ_POLE';
        }
        // pin 类 = 杆/管等（非 oval/box/tri）：圆圈 + 符号字在圆内。
        final isPin = !lt.isOval && !lt.isBox && !lt.isTri;
        if (lt.isBox || lt.isOval) {
          if (disp.isNotEmpty) {
            var wChars = 0.0;
            for (final ch in disp.runes) {
              wChars += ch < 128 ? 0.55 : 1.0;
            }
            final textW = wChars * labelFontM;
            final boxW = textW + _mm(2.0);
            final boxH = labelFontM + _mm(1.6);
            _appendRect(c, 'BiaoQian', x - boxW / 2, y - boxH / 2,
                x + boxW / 2, y + boxH / 2);
            if (lt.id == 'crossbox') {
              // 交接箱 = 矩形 + 对角线 X（通信行业符号）
              _appendLine(c, 'BiaoQian', x - boxW / 2, y - boxH / 2,
                  x + boxW / 2, y + boxH / 2);
              _appendLine(c, 'BiaoQian', x - boxW / 2, y + boxH / 2,
                  x + boxW / 2, y - boxH / 2);
            }
            _appendTextCentered(c, 'BiaoQian', x, y, labelFontM, disp);
          } else {
            _appendInsert(c, 'BiaoQian', block, x, y, sx: symScale, sy: symScale);
            _appendFiberBoxLabel(c, l, x, y, symScale);
          }
        } else if (isPin) {
          // pin 类（杆/管等）：圆圈 + 符号字在圆内（对齐地图样式；
          // 用户要求：圆内除字之外别无其他）。
          final rM = _pinRadius();
          _appendCircle(c, 'BiaoQian', x, y, rM);
          if (lt.symbol.isNotEmpty) {
            // 圆内字与 pin 圆同步缩放（字高 = 圆半径）
            _appendTextCentered(c, 'BiaoQian', x, y, pinFontM, lt.symbol);
          }
        } else {
          _appendInsert(c, 'BiaoQian', block, x, y, sx: symScale, sy: symScale);
        }
        // 有拓扑时箱体（光交/分光箱/分纤盒/ONU/机房/基站）的文字
        // 由地理式配线统一输出标签牌，这里只画符号，避免文字重叠
        // 但分纤盒的正规槽位箱文字（2槽位箱/4槽位箱）必须保留——用户 2026-10-08 要求
        final topoBox = hasTopo && (lt.role >= 1 && lt.role <= 4 || lt.role == 7);
        if (topoBox) {
          _appendHoleDots(c, x, y + holeDotsUpM, l); // 芯线/管孔占用可视化
          _appendFiberBoxLabel(c, l, x, y, symScale);
          continue;
        }
        // 箱体/人孔文字已在框内（上方入框画法）；pin 类符号字已在圆内，
        // 上方只注记点名（有名称才注）；引上（tri）保持符号/名称在上方。
        final pointName = l.name.trim();
        if (isPin) {
          if (pointName.isNotEmpty) {
            _text(c, 'BiaoQian', x, y + offUpM, labelFontM, pointName,
                style: true);
          }
        } else if (!lt.isBox && !lt.isOval && disp.isNotEmpty) {
          _text(c, 'BiaoQian', x, y + offUpM, labelFontM, disp, style: true);
        }
        if (l.holes > 0) {
          _appendHoleDots(c, x, y + holeDotsUpM, l);
          _text(c, 'BiaoQian', x, y - offDownM, noteFontM,
              '${l.holes}孔${l.usedHoles > 0 ? '用${l.usedHoles}' : ''}',
              style: true);
        }
        if (l.note.trim().isNotEmpty) {
          _text(c, 'BiaoQian', x, y - offNoteM, noteFontM, l.note.trim(),
              style: true);
        }
        // 现场取证照片数（竣工溯源：CAD 图上知道该点有 N 张现场照片）
        if (l.photoPaths.isNotEmpty) {
          _text(c, 'BiaoQian', x, y - offPhotoM, noteFontM,
              '[${l.photoPaths.length}图]', style: true);
        }
      }
    }

    // 配线（地理式，对齐手绘样图）：拓扑父子箱体在路由图真实位置上用粗黑线连接，
    // 沿线标注箱体间距离与光缆型号，箱体上方挂标签牌（名称/分光比/备注）。
    if (hasTopo) {
      try {
        _appendTopoGeo(c, labels, baseLon, baseLat, scaleX, scaleY, version);
      } catch (e) {
        // 拓扑异常不阻塞路由图导出（如节点数据不全）
      }
    }

    // 拉直沿线配线图（可选附加，长杆路出图）：放路由图右侧，按 500m 分图幅。
    // 2026-10-09：有 FiberLink 时用新的跟路由走向配线图，跳过老的不跟走向的
    if (hasTopo && straightenedWiring && fiberLinks.isEmpty) {
      try {
        var minLatW = 90.0, maxLatW = -90.0, maxLonW = -180.0;
        for (final l in labels) {
          if (l.lat < minLatW) minLatW = l.lat;
          if (l.lat > maxLatW) maxLatW = l.lat;
          if (l.lon > maxLonW) maxLonW = l.lon;
        }
        final routeW = (maxLonW - labels.first.lon) * scaleX;
        // 右侧留白用**纸面毫米**（60mm），不再用 60 真实米（1:3000 下=0.02 单位）
        final ox = routeW + _mm(60);
        final oyTop = (maxLatW - baseLat) * scaleY; // 顶部对齐路由图顶部
        final wiringExtent = _appendWiringDiagram(c, labels, ox, oyTop,
            baseLon, baseLat, scaleX, scaleY, version, ps);
        if (wiringExtent[0] > extMaxX) extMaxX = wiringExtent[0];
        if (wiringExtent[1] < extMinY) extMinY = wiringExtent[1];
        if (wiringExtent[2] > extMaxY) extMaxY = wiringExtent[2];
      } catch (e) {
        // 拉直配线异常不阻塞主图导出
      }
    }

    // 人工光缆配线图（Phase 3）：基于 FiberLink。
    // 2026-10-09 用户定版：**与路由图同比例（1:3000）、走向完全一致**——
    // 几何由 layoutWiringDiagram 直角简化而来（保留每段真实米数），
    // 落图时统一除以 ps，于是两张图**叠合可严格对齐**，就是缩小版的路由图。
    // 配线图 = 地图里的纤拓扑结构：只含 FiberLink 两端的设备
    if (fiberLinks.isNotEmpty) {
      try {
        final topoIds = <String>{};
        for (final l in fiberLinks) {
          topoIds.add(l.fromDeviceId);
          topoIds.add(l.toDeviceId);
        }
        final topoDevices = [
          for (final d in labels)
            if (topoIds.contains(d.id)) d
        ];
        // 直角简化：每段步长取真实地理米数（在 layoutWiringDiagram 内部完成），
        // segLen 仅用于不在路由链上的设备兜底落点与包络留白（纸面毫米量级）。
        final layout = layoutWiringDiagram(topoDevices, fiberLinks, labels,
            segLen: 40);
        if (layout.nodes.isNotEmpty && layout.path.length >= 2) {
          // **同比例系数**：与路由图共用 1/ps，叠合严格对齐
          final wiringScale = _geo(1.0, ps);
          final fontM = _mm(2.5);
          final smallFontM = _mm(2.0);

          // 先算配线图自身的包围盒（相对原点的极值），再据此定原点 ——
          // 2026-10-09 修掉的越框事故：旧实现直接 `oy = extMinY - 30mm`，
          // 但配线图自身高度可达 118mm（原点在路径起点），下沿直接戳出图框 11mm。
          // 正确做法：把「路径 + 标注留白」的极值算出来，整体下移到框内。
          var wMinX = double.infinity, wMaxX = -double.infinity;
          var wMinY = double.infinity, wMaxY = -double.infinity;
          void track(double x, double y) {
            if (x < wMinX) wMinX = x;
            if (x > wMaxX) wMaxX = x;
            if (y < wMinY) wMinY = y;
            if (y > wMaxY) wMaxY = y;
          }

          for (final n in layout.nodes) {
            track(n.x, n.y);
            // 节点周围的标注留白（成端引线/分光器说明在左下 10mm）
            track(n.x - _mm(10.0), n.y - _mm(12.0));
            track(n.x + _mm(20.0), n.y + _mm(5.0));
          }
          for (final e in layout.edges) {
            track(e.from.x, e.from.y);
            track(e.to.x, e.to.y);
            // 连线中点标注：型号在上 3mm、长度在下 5mm
            final mx = (e.from.x + e.to.x) / 2;
            final my = (e.from.y + e.to.y) / 2;
            track(mx, my - _mm(5.0) / wiringScale);
            track(mx, my + _mm(3.0) / wiringScale);
          }
          if (wMinX > wMaxX || wMinY > wMaxY) wMinY = wMinX = 0;

          // 缩放到模型单位后的实际尺寸
          final wH = (wMaxY - wMinY) * wiringScale;
          // 原点：框内左上角 —— 配线图整体落在路由图下方的空白带里
          final gap = _mm(20.0); // 与路由图的垂直间距（纸面 20mm）
          final ox = extMinX;
          // 若下方空间不够（wH > 可用高度），则放到路由图**右侧**（更宽裕）
          final availBelow = extMinY - extMaxY;
          final double oy;
          if (wH + gap <= availBelow.abs() && availBelow < 0) {
            // extMinY 在下、extMaxY 在上：向下生长到 extMinY - gap
            oy = extMinY - gap - wMaxY * wiringScale;
          } else {
            oy = extMaxY - gap - wMaxY * wiringScale;
          }

          // 画直角简化路径（配线图走向跟路由一致）
          for (var i = 1; i < layout.path.length; i++) {
            final p1 = layout.path[i - 1];
            final p2 = layout.path[i];
            _appendLine(c, 'PeiXianTu', ox + p1.x * wiringScale,
                oy + p1.y * wiringScale, ox + p2.x * wiringScale,
                oy + p2.y * wiringScale);
          }
          // 路径本身也要纳入包围盒（节点只覆盖了部分路径点）
          for (final p in layout.path) {
            final px = ox + p.x * wiringScale;
            final py = oy + p.y * wiringScale;
            if (px < extMinX) extMinX = px;
            if (px > extMaxX) extMaxX = px;
            if (py < extMinY) extMinY = py;
            if (py > extMaxY) extMaxY = py;
          }
          // 找出端点（无出边的节点）：标成端处
          final hasOut = <String>{};
          for (final e in layout.edges) {
            hasOut.add(e.from.device.id);
          }
          // 画节点箱体（在路径点上），符号按纸面毫米尺寸落图
          for (final n in layout.nodes) {
            final cx = ox + n.x * wiringScale;
            final cy = oy + n.y * wiringScale;
            // 纤箱判断（2026-10-09）：typeId 可能是 fiberbox/fdcab/termbox 或其他；
            // 兜底：箱体形状且非分光器/光交/ONU/机房/基站，一律按槽位箱画
            final lt = LabelType.fromId(n.device.typeId);
            final isFiberBox = n.device.typeId == 'fiberbox' ||
                n.device.typeId == 'fdcab' ||
                n.device.typeId == 'termbox' ||
                n.device.name.contains('分纤') ||
                (lt.isBox &&
                    n.device.typeId != 'splitterbox' &&
                    n.device.typeId != 'crossbox' &&
                    n.device.typeId != 'onubox' &&
                    n.device.typeId != 'room' &&
                    n.device.typeId != 'bts');
            if (isFiberBox) {
              _appendInsert(c, 'PeiXianTu', 'HZ_FIBERBOX', cx, cy);
              final slotText = n.device.name.contains('4槽')
                  ? '4槽位箱'
                  : '2槽位箱';
              // 槽位箱符号半宽 5mm（块定义 10mm 宽），文字右移 2mm
              _text(c, 'PeiXianTu', cx + _mm(5.0) + _mm(2.0), cy, fontM,
                  slotText);
            } else {
              final hw = _mm(9.0), hh = _mm(5.0);
              _appendRect(c, 'PeiXianTu', cx - hw, cy - hh, cx + hw, cy + hh);
              _text(c, 'PeiXianTu', cx - hw + _mm(1.0), cy - fontM / 2,
                  fontM, n.label);
            }
            // 成端处：无出边的端点加引线标注（引线长 8mm，文字再右移 1mm）
            if (!hasOut.contains(n.device.id)) {
              _appendLine(c, 'PeiXianTu', cx + _mm(6.0), cy - _mm(3.0),
                  cx + _mm(14.0), cy - _mm(8.0));
              _text(c, 'PeiXianTu', cx + _mm(15.0), cy - _mm(10.0), fontM,
                  '成端处');
            }
            // 分光器标注
            if (n.device.typeId == 'splitterbox') {
              final splitterInfo = n.device.note.contains('1:')
                  ? n.device.note
                  : n.device.name;
              if (splitterInfo.isNotEmpty) {
                _text(c, 'PeiXianTu', cx - _mm(10.0), cy - _mm(10.0),
                    smallFontM, '分光器:$splitterInfo');
              }
            }
            if (cy - _mm(12.0) < extMinY) extMinY = cy - _mm(12.0);
            if (cx + _mm(10.0) > extMaxX) extMaxX = cx + _mm(10.0);
          }
          // 路径分段标光缆型号+长度（按连线）
          for (final e in layout.edges) {
            final x1 = ox + e.from.x * wiringScale;
            final y1 = oy + e.from.y * wiringScale;
            final x2 = ox + e.to.x * wiringScale;
            final y2 = oy + e.to.y * wiringScale;
            final midX = (x1 + x2) / 2;
            final midY = (y1 + y2) / 2;
            if (e.link.reno == RenoState.added) {
              fiberNewLenM += e.link.lengthM;
            } else if (e.link.reno == RenoState.removed) {
              fiberRemoveLenM += e.link.lengthM;
            }
            final spec = e.link.fullSpec;
            if (spec.isNotEmpty) {
              _text(c, 'PeiXianTu', midX, midY + _mm(3.0), smallFontM, spec);
            }
            if (e.link.lengthM > 0) {
              _text(c, 'PeiXianTu', midX, midY - _mm(5.0), smallFontM,
                  '长${e.link.lengthM.toStringAsFixed(1)}');
            }
          }
        }
      } catch (e) {
        // 配线图异常不阻塞主图导出
      }
    }

    // 改造工程量注记（如有）：图框下扩以包含注记（按线路范围，不被底图污染）
    // 2026-10-05：用户要求删除右下角设计单位/工程名称图框（标题栏），
    // 不再为其预留高度；仅改造注记需要时下扩。
    final hasRenoStat = renoNewLenM > 0 ||
        renoRemoveLenM > 0 ||
        fiberNewLenM > 0 ||
        fiberRemoveLenM > 0;
    if (hasRenoStat) {
      final renoH = _mm(10) + _mm(6 * 2 + 4);
      if (routeMinY - renoH < extMinY) extMinY = routeMinY - renoH;
    }

    // 图框（内容包围盒外加 10mm 边距）+ 图例栏 + 指北针 + 比例标注
    // 2026-10-05：删除标题栏（设计单位/工程名称图框），用户要求。
    //
    // 顺序要点：**先算图例高度再画图框** —— 图例从右上角向下生长，
    // 若类型很多可能触及下边界，那时要把图框再下扩（保证图例不被裁）。
    var legendBottom = double.infinity;
    if (showLegend) {
      legendBottom = _appendLegend(c, labels, extMaxX, extMaxY);
      if (legendBottom < extMinY) extMinY = legendBottom;
    }
    _appendFrame(c, extMinX, extMinY, extMaxX, extMaxY);
    _appendNorthArrow(c, extMaxX, extMaxY);
    // 出图比例标注（正规设计图必备，图框左下角）：
    // 审图/打印时一眼确认这张图是按 1:N 出的，避免"图上量距对不上"。
    _text(c, 'TuQian', extMinX - _mm(10) + _mm(4),
        extMinY - _mm(10) + _mm(4), _mm(3.0), '比例 $plotLabel',
        style: true);

    // 改造工程量注记（线路下方）：新增/拆除长度，无改造时不画
    // 2026-10-05：标题栏已删除，注记直接放在线路下方 10mm 处。
    final hasReno = renoNewLenM > 0 ||
        renoRemoveLenM > 0 ||
        fiberNewLenM > 0 ||
        fiberRemoveLenM > 0;
    if (hasReno) {
      final statFontM = _mm(3.0);
      final sx = routeMaxX - _mm(120);
      var sy = routeMinY - _mm(10) - _mm(6);
      final stats = <String>[];
      if (renoNewLenM > 0 || renoRemoveLenM > 0) {
        stats.add(
            '杆路改造：新增${_formatDistNoUnit(renoNewLenM)}米 拆除${_formatDistNoUnit(renoRemoveLenM)}米');
      }
      if (fiberNewLenM > 0 || fiberRemoveLenM > 0) {
        stats.add(
            '光缆改造：新增${_formatDistNoUnit(fiberNewLenM)}米 拆除${_formatDistNoUnit(fiberRemoveLenM)}米');
      }
      for (final s in stats) {
        _text(c, 'TuQian', sx, sy, statFontM, s, style: true);
        sy -= _mm(6);
      }
    }

    sb.write('0\nENDSEC\n');

    // OBJECTS 段（R2000 必需）：根命名对象字典 + ACAD_GROUP。
    if (version == DxfVersion.r2000) {
      _appendObjectsSection(c);
    }

    sb.write('0\nEOF\n');

    // 回填 R2000 HEADER 占位符（句柄种子 / 图幅范围）
    // **必须 replaceAll**：EXTMIN/LIMMIN 等占位符各出现两次（此前用 replaceFirst，
    // 会留下第二处 `@@EXTMINX@@` 字面量进文件 —— 那正是 R2000 打开报"修复"的诱因之一）。
    var text = sb.toString();
    if (version == DxfVersion.r2000) {
      text = text
          .replaceAll('@@HANDSEED@@', h.nextValue.toRadixString(16).toUpperCase())
          .replaceAll('@@EXTMINX@@', _fmt(extMinX))
          .replaceAll('@@EXTMINY@@', _fmt(extMinY))
          .replaceAll('@@EXTMAXX@@', _fmt(extMaxX))
          .replaceAll('@@EXTMAXY@@', _fmt(extMaxY));
    }

    // 【防复发闸门】产出前用「严格结构校验器」自检：结构不合法立即抛错，
    //  绝不再把「打不开的文件」写盘（上批正是被字符串断言骗过去才出的事故）。
    final problems = DxfStructureValidator.validate(text, version: version);
    if (problems.isNotEmpty) {
      throw StateError('DXF 结构校验未通过，已阻止写出非法文件：\n- ${problems.join('\n- ')}');
    }

    // 两版本均用 GBK 字节写盘（中文 CAD 默认 ANSI_936 代码页），避免乱码
    await robustWriteBytes(f, _gbkEncode(text));
    return DxfExportResult(f, warnings, report, renoNewLenM, renoRemoveLenM,
        fiberNewLenM, fiberRemoveLenM);
  }

  /// GBK 编码（带一次幂等重试）。
  ///
  /// `gbk_codec` 的全局 codec `gbk_bytes` 是**惰性初始化**的顶层变量，其构造会
  /// 构建约两万余项的码表字面量；在极端并行负载（如 `flutter test` 全量并发）
  /// 下首次初始化偶发瞬时失败（报
  /// `type 'List<dynamic>' is not a subtype of type 'String'`；
  /// Dart 惰性初始化抛出后，下次访问会重新执行初始化）。
  /// 此处重试一次：**输出字节完全不变**，不改 DXF/GBK 任何语义。
  static List<int> _gbkEncode(String text) {
    try {
      return gbk_bytes.encode(text);
    } catch (_) {
      return gbk_bytes.encode(text); // 二次访问重新执行惰性初始化
    }
  }

  // ---- 实体输出辅助 ----

  /// 通用单行文字。R12/R2000 共用。
  ///
  /// **全图统一宋体**：默认样式 `SimSun`（simsun.ttc），不再输出无样式
  /// （Standard/txt.shx）的文字。
  /// **全图文字纯白**（用户要求）：实体级白色覆盖图层色——路名层深灰
  /// 在 CAD 黑底上几乎看不见，统一纯白最保险。
  /// - [styleName] 指定具体文字样式名（如路名的 `SongTi`），优先于默认；
  /// - [style] 为历史参数，保留兼容（等价于默认）；
  /// - [angle] 非空时写旋转 `50`。
  static void _text(_Ctx c, String layer, double x, double y, double h,
      String text, {double? angle, bool style = false, String? styleName}) {
    final t = text.replaceAll('\r', ' ').replaceAll('\n', ' ');
    final sn = styleName ?? 'SimSun';
    c.ent('TEXT', layer, 'AcDbText');
    c.sb.write('62\n7\n'); // ACI 白（实体级，覆盖图层色）
    if (c.r2000) c.sb.write('420\n16777215\n'); // 真彩纯白
    c.sb.write('7\n$sn\n');
    c.sb.write('10\n${_fmt(x)}\n20\n${_fmt(y)}\n30\n0\n40\n${_fmt(h)}\n');
    if (angle != null) c.sb.write('50\n${angle.toStringAsFixed(1)}\n');
    c.sb.write('1\n$t\n');
    if (c.r2000) c.sb.write('100\nAcDbText\n');
  }

  static void _appendLine(_Ctx c, String layer,
      double x1, double y1, double x2, double y2) {
    c.ent('LINE', layer, 'AcDbLine');
    c.sb.write('10\n${_fmt(x1)}\n20\n${_fmt(y1)}\n30\n0\n11\n'
        '${_fmt(x2)}\n21\n${_fmt(y2)}\n31\n0\n');
  }

  /// 多段线（**版本分支**）：
  /// - R2000 → `LWPOLYLINE`（`90` 点数 / `70` 闭合位 / `43` 常宽）；
  /// - R12   → 经典 `POLYLINE/VERTEX/SEQEND`（`40`/`41` 常宽）。
  ///
  /// [closed] 为 true 时闭合（如建筑轮廓）；[width] > 0 写常宽。
  static void _appendPolyline(_Ctx c, String layer,
      List<List<double>> pts,
      {bool closed = false,
      double width = 0,
      DxfVersion version = DxfVersion.r12}) {
    if (pts.length < 2) return;
    if (version == DxfVersion.r2000) {
      c.ent('LWPOLYLINE', layer, 'AcDbPolyline');
      c.sb.write('90\n${pts.length}\n70\n${closed ? 1 : 0}\n');
      if (width > 0) c.sb.write('43\n${_fmt(width)}\n');
      for (final p in pts) {
        c.sb.write('10\n${_fmt(p[0])}\n20\n${_fmt(p[1])}\n');
      }
    } else {
      c.sb.write('0\nPOLYLINE\n8\n$layer\n66\n1\n70\n${closed ? 1 : 0}\n');
      if (width > 0) {
        c.sb.write('40\n${_fmt(width)}\n41\n${_fmt(width)}\n');
      }
      for (final p in pts) {
        c.sb.write('0\nVERTEX\n8\n$layer\n'
            '10\n${_fmt(p[0])}\n20\n${_fmt(p[1])}\n30\n0\n');
      }
      c.sb.write('0\nSEQEND\n8\n$layer\n');
    }
  }

  /// 管廊双线：整链一条闭合偏移多段线（转角用平均法向自然对接，
  /// 不再逐段独立封口导致转角出头）。
  static void _appendCorridor(_Ctx c, List<List<double>> pts, double w,
      DxfVersion version) {
    if (pts.length < 2 || w <= 0) return;
    final n = pts.length;
    final nrm = _avgNormals(pts);
    final w2 = w / 2.0;
    final outline = <List<double>>[
      for (var i = 0; i < n; i++)
        [pts[i][0] + nrm[i][0] * w2, pts[i][1] + nrm[i][1] * w2],
      for (var i = n - 1; i >= 0; i--)
        [pts[i][0] - nrm[i][0] * w2, pts[i][1] - nrm[i][1] * w2],
    ];
    _appendPolyline(c, 'GuanLang', outline, closed: true, version: version);
  }

  /// 折线各顶点平均法向（转角两侧线段法向均值归一化；端点用自身线段法向）。
  /// 管廊双线与道路双线描边共用此算法（转角自然对接，不出头）。
  static List<List<double>> _avgNormals(List<List<double>> pts) {
    final n = pts.length;
    final nrm = <List<double>>[];
    for (var i = 0; i < n; i++) {
      List<double> dPrev, dNext;
      if (i == 0) {
        dPrev = dNext = _dir(pts[0], pts[1]);
      } else if (i == n - 1) {
        dPrev = dNext = _dir(pts[n - 2], pts[n - 1]);
      } else {
        dPrev = _dir(pts[i - 1], pts[i]);
        dNext = _dir(pts[i], pts[i + 1]);
      }
      var nx = -(dPrev[1] + dNext[1]) / 2;
      var ny = (dPrev[0] + dNext[0]) / 2;
      final len = math.sqrt(nx * nx + ny * ny);
      if (len < 1e-9) {
        nx = -dPrev[1];
        ny = dPrev[0];
      } else {
        nx /= len;
        ny /= len;
      }
      nrm.add([nx, ny]);
    }
    return nrm;
  }

  /// 沿折线法向整体偏移 [off] 米（正=左法向，负=右法向），返回偏移后折线（不闭合）。
  static List<List<double>> _offsetPolyline(List<List<double>> pts, double off) {
    final n = pts.length;
    if (n < 2) return const [];
    final nrm = _avgNormals(pts);
    return [
      for (var i = 0; i < n; i++)
        [pts[i][0] + nrm[i][0] * off, pts[i][1] + nrm[i][1] * off]
    ];
  }

  static List<double> _dir(List<double> a, List<double> b) {
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-9) return [1.0, 0.0];
    return [dx / len, dy / len];
  }

  /// 指北针：图框内右上角，圆 + N 字 + 指针三角。尺寸一律**纸面毫米**。
  static void _appendNorthArrow(_Ctx c, double maxX, double maxY) {
    final cx = maxX - _mm(14);
    final cy = maxY - _mm(12);
    final r = _mm(6.0);
    // 外圆（R12 直接输出 CIRCLE）
    c.ent('CIRCLE', 'BeiFangZhen', 'AcDbCircle');
    c.sb.write('10\n${_fmt(cx)}\n20\n${_fmt(cy)}\n30\n0\n40\n${_fmt(r)}\n');
    // 指针三角：尖朝上
    _appendTri(c, 'BeiFangZhen', cx, cy - _mm(0.8), _mm(2.4));
    // N 字
    _appendTextCentered(c, 'BeiFangZhen', cx, cy + r + _mm(1.5), _mm(3.5), 'N');
  }

  /// 图框：内容包围盒外加 **10mm 边距**画边框（正规设计图标准内边距）。
  static void _appendFrame(_Ctx c, double minX,
      double minY, double maxX, double maxY) {
    final m = _mm(10.0);
    final x0 = minX - m, y0 = minY - m;
    final x1 = maxX + m, y1 = maxY + m;
    _appendRect(c, 'TuQian', x0, y0, x1, y1);
  }

  /// 图例栏：图框内**右上角**，纵向排列本次用到的符号 + 类型名。
  /// 全部尺寸按**纸面毫米**（行距 6mm、字高 2.5mm）。
  ///
  /// 返回图例画到的**最低 y**，供调用方在必要时下扩图框（保证绝不越框）。
  ///
  /// ## 2026-10-09 从「左下角」改为「右上角」
  ///
  /// 旧实现锚在 `minY - 10mm + 4mm`（图框左下内侧 6mm），但图例是**向下生长**的：
  /// 标题 + N 行 × 6mm。类型一多（杆+管+光交+分光+分纤+引上 = 6 类 = 42mm），
  /// 就从左下角**向下溢出图框**，压在配线图上（实测溢出 11mm）。
  ///
  /// 改锚右上角后同样向下生长，但右上到下的空间就是整个图框高度，通常远够。
  /// 横向与右上角的指北针错开（图例靠左、指北针靠右，见 [_appendNorthArrow]）。
  static double _appendLegend(_Ctx c, List<MapLabel> labels,
      double maxX, double maxY) {
    final used = <String>{};
    for (final l in labels) {
      if (l.typeId == 'track' || l.typeId == 'none' || l.typeId == 'text') {
        continue;
      }
      used.add(l.typeId);
    }
    if (used.isEmpty) return double.infinity;
    // 按 LabelType.all 的顺序输出，保持图例口径一致
    final ordered = LabelType.all.where((t) => used.contains(t.id)).toList();
    final m = _mm(10.0);
    // 右上角内侧起排（距顶 3mm），逐行向下生长
    final lx = maxX - m - _mm(40.0); // 图例栏宽约 40mm（符号 + 名称）
    var y = maxY - m - _mm(3.0);
    _text(c, 'TuQian', lx, y, _mm(3.0), '图  例');
    y -= _mm(7.0);
    for (final t in ordered) {
      String block;
      if (t.isOval) {
        block = 'HZ_OVAL';
      } else if (t.isBox) {
        block = 'HZ_BOX';
      } else if (t.isTri) {
        block = 'HZ_TRI';
      } else {
        block = 'HZ_POLE';
      }
      _appendInsert(c, 'TuQian', block, lx + _mm(2.0), y);
      _text(c, 'TuQian', lx + _mm(5.0), y - _mm(1.0), _mm(2.5), t.name);
      y -= _mm(6.0);
    }
    return y;
  }

  /// 桩号文字：K0+000 格式（千米 + 米，米保留 1 位小数）。字高 2.5mm。
  static void _appendStake(_Ctx c, double x, double y, double cum) {
    final km = cum ~/ 1000;
    final m = cum - km * 1000;
    final mStr = m.toStringAsFixed(1).padLeft(5, '0');
    _text(c, 'ZhuangHao', x + _mm(1.5), y + _mm(3.0), _mm(2.5),
        'K$km+$mStr');
  }

  /// 盘留数字格式：整数或 1 位小数。
  static String _formatSlack(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  /// 芯线/管孔占用可视化：一排小圆，已占用 = 圆内打叉，空闲 = 空心。
  /// 最多画 24 孔，避免一行拉太长。尺寸按**纸面毫米**。
  static void _appendFiberBoxLabel(
      _Ctx c, MapLabel l, double x, double y, double symScale) {
    // 分纤盒（纤）：正规槽位箱文字标注（2026-10-08 用户要求）
    // 2槽/4槽同图形，仅文字区分；字高 2.5mm 纸面，矩形右侧
    // 兜底：名字含分纤也算
    final lt = LabelType.fromId(l.typeId);
    final isFb = l.typeId == 'fiberbox' ||
        l.typeId == 'fdcab' ||
        l.typeId == 'termbox' ||
        l.name.contains('分纤') ||
        (lt.isBox &&
            l.typeId != 'splitterbox' &&
            l.typeId != 'crossbox' &&
            l.typeId != 'onubox' &&
            l.typeId != 'room' &&
            l.typeId != 'bts');
    if (!isFb) return;
    final slotText = l.name.contains('4槽') ? '4槽位箱' : '2槽位箱';
    // HZ_FIBERBOX 块宽 10mm（半宽 5mm），插入缩放 symScale 恒为 1.0
    final boxHalfW = _mm(5.0) * symScale;
    _text(c, 'BiaoQian', x + boxHalfW + _mm(1.5), y, _mm(2.5), slotText);
  }

  static void _appendHoleDots(_Ctx c, double cx, double cy, MapLabel l) {
    final n = l.holes;
    if (n <= 0 || n > 24) return;
    final r = _mm(0.7), gap = _mm(2.0);
    final x0 = cx - (n - 1) * gap / 2;
    final used = l.usedHoles.clamp(0, n);
    for (var i = 0; i < n; i++) {
      final x = x0 + i * gap;
      c.ent('CIRCLE', 'BiaoQian', 'AcDbCircle');
      c.sb.write('10\n${_fmt(x)}\n20\n${_fmt(cy)}\n30\n0\n40\n${_fmt(r)}\n');
      if (i < used) {
        // 占用孔：圆内打叉
        _appendLine(c, 'BiaoQian', x - r, cy - r, x + r, cy + r);
        _appendLine(c, 'BiaoQian', x - r, cy + r, x + r, cy - r);
      }
    }
  }

  /// 地理式配线（对齐手绘样图）：拓扑父子箱体在真实位置连粗黑线（宽 0.6mm），
  /// 沿线旋转标注箱体间距离与光缆型号；箱体上方挂标签牌（小矩形 + 名称），
  /// 牌下依次为分光比/孔数与备注。**所有偏移/字号按纸面毫米。**
  static void _appendTopoGeo(_Ctx c, List<MapLabel> labels,
      double baseLon, double baseLat, double scaleX, double scaleY,
      DxfVersion version) {
    final roots = Topology.buildTree(labels);
    Topology.assignTitles(roots);
    final nodes = Topology.flatten(roots);
    final pos = <String, List<double>>{};
    for (final n in nodes) {
      pos[n.src.id] = [
        (n.src.lon - baseLon) * scaleX,
        (n.src.lat - baseLat) * scaleY,
      ];
    }

    // 父子连线 + 段标注
    for (final n in nodes) {
      final p = n.parent;
      if (p == null) continue;
      final p1 = pos[p.src.id]!, p2 = pos[n.src.id]!;
      // 粗黑折线（R2000=LWPOLYLINE / R12 经典 POLYLINE 常宽 0.6mm）
      _appendPolyline(c, 'PeiXianTu', [p1, p2],
          width: _mm(0.6), version: version);
      final dx = p2[0] - p1[0], dy = p2[1] - p1[1];
      final len = math.sqrt(dx * dx + dy * dy);
      var angle = len > 1e-6 ? math.atan2(dy, dx) * 180 / math.pi : 0.0;
      if (angle > 90 || angle < -90) angle += 180;
      final dist = _haversine(p.src.lat, p.src.lon, n.src.lat, n.src.lon);
      final mx = (p1[0] + p2[0]) / 2, my = (p1[1] + p2[1]) / 2;
      // 距离放线上方，光缆型号放线下方
      _text(c, 'PeiXianTu', mx, my + _mm(1.2), _mm(2.5), dist.toStringAsFixed(1),
          angle: angle, style: true);
      if (n.cable.isNotEmpty) {
        _text(c, 'PeiXianTu', mx, my - _mm(2.6), _mm(2.0), n.cable,
            angle: angle, style: true);
      }
    }

    // 箱体标签牌（对齐手绘图上"2槽位箱"式小牌）：牌内为名称，
    // 牌下依次为分光比/孔数、备注
    for (final n in nodes) {
      final xy = pos[n.src.id]!;
      final x = xy[0], y = xy[1];
      final title = n.title;
      // 牌宽按标题字数估算（每字 2.6mm + 两侧留白 3mm）
      final tagW = title.length * _mm(2.6) + _mm(3.0);
      _appendRect(c, 'PeiXianTu', x - tagW / 2, y + _mm(3.5),
          x + tagW / 2, y + _mm(7.0));
      _appendTextCentered(c, 'PeiXianTu', x, y + _mm(4.2), _mm(2.2), title);
      if (n.sub.isNotEmpty) {
        _appendTextCentered(c, 'PeiXianTu', x, y - _mm(4.2), _mm(2.2), n.sub);
      }
      final note = n.src.note.trim();
      if (note.isNotEmpty) {
        _appendTextCentered(c, 'PeiXianTu', x, y - _mm(6.8), _mm(2.2), note);
      }
    }
  }

  /// 椭圆符号：R12 无椭圆实体，用 N 段折线闭合近似。
  static void _appendOval(_Ctx c, String layer,
      double cx, double cy, double ra, double rb) {
    const n = 16;
    var px = cx + ra, py = cy;
    for (var i = 1; i <= n; i++) {
      final th = 2 * math.pi * i / n;
      final qx = cx + ra * math.cos(th);
      final qy = cy + rb * math.sin(th);
      _appendLine(c, layer, px, py, qx, qy);
      px = qx;
      py = qy;
    }
  }

  static void _appendCircle(_Ctx c, String layer, double cx, double cy, double r) {
    c.ent('CIRCLE', layer, 'AcDbCircle');
    c.sb.write('10\n${_fmt(cx)}\n20\n${_fmt(cy)}\n30\n0\n40\n${_fmt(r)}\n');
  }

  static void _appendRect(_Ctx c, String layer,
      double x0, double y0, double x1, double y1) {
    _appendLine(c, layer, x0, y0, x1, y0);
    _appendLine(c, layer, x1, y0, x1, y1);
    _appendLine(c, layer, x1, y1, x0, y1);
    _appendLine(c, layer, x0, y1, x0, y0);
  }

  static void _appendTri(_Ctx c, String layer, double cx, double cy, double s) {
    final ax = cx, ay = cy + s;
    final bx = cx - s * 0.87, by = cy - s * 0.5;
    final px = cx + s * 0.87, py = cy - s * 0.5;
    _appendLine(c, layer, ax, ay, bx, by);
    _appendLine(c, layer, bx, by, px, py);
    _appendLine(c, layer, px, py, ax, ay);
  }

  /// 符号块定义段：人孔椭圆 / 箱体 / 引上三角 / 杆路圆叉。
  static void _appendBlocksSection(_Ctx c, DxfVersion version) {
    c.sb.write('0\nSECTION\n2\nBLOCKS\n');
    // R2000 需 *Model_Space 块（实体属主 330=1F 指向它，句柄固定为 1F）。
    if (version == DxfVersion.r2000) {
      c.sb.write('0\nBLOCK\n5\n1F\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockBegin\n2\n*Model_Space\n70\n0\n'
          '10\n0.000\n20\n0.000\n30\n0.000\n3\n*Model_Space\n1\n\n');
      c.sb.write('0\nENDBLK\n5\n${c.h.next()}\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockEnd\n');
    }
    var b = StringBuffer();
    var bc = _Ctx(b, version, c.h);
    // 符号块基准尺寸按**纸面毫米**给定（人孔 6×3.5mm、箱体 5×3mm、引上边 3mm、
    // 杆圆 r=1.2mm——通信工程制图惯例，符号远小于文字块、与字号协调），
    // 但**必须用 [_mm()] 换算成模型单位后再写进块定义**。
    //
    // 2026-10-09 修掉的严重事故：块定义里直接写 `10.0`（想当然当成"已在模型
    // 单位"），而 INSERT 缩放是 1.0 —— 于是 10mm 的槽位箱在 1:3000 下变成
    // 10 个模型单位 = 30 公里，整个符号比图纸大 1000 倍，渲染出来内容被压成
    // 一个点（ezdxf bbox 实测 INSERT 占 10.0 而图框仅 0.2467）。
    //
    // 记住：块定义 = 模型单位；INSERT 缩放 = 1.0。两者必须同尺度。
    _appendOval(bc, '0', 0, 0, _mm(3.0), _mm(1.75));
    _appendBlock(c, version, 'HZ_OVAL', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    _appendRect(bc, '0', -_mm(2.5), -_mm(1.5), _mm(2.5), _mm(1.5));
    _appendBlock(c, version, 'HZ_BOX', b.toString());
    // 正规槽位箱符号（2026-10-08 用户联通竣工图实测）：10.0×4.4 矩形（纸面 mm），
    // 白色；2槽/4槽同尺寸，仅文字区分。专用于分纤盒（纤）。
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    _appendRect(bc, '0', -_mm(5.0), -_mm(2.2), _mm(5.0), _mm(2.2));
    _appendBlock(c, version, 'HZ_FIBERBOX', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    _appendTri(bc, '0', 0, 0, _mm(1.5));
    _appendBlock(c, version, 'HZ_TRI', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    bc.ent('CIRCLE', '0', 'AcDbCircle');
    bc.sb.write('10\n0\n20\n0\n30\n0\n40\n${_fmt(_mm(1.2))}\n');
    _appendLine(bc, '0', -_mm(1.2), 0, _mm(1.2), 0);
    _appendLine(bc, '0', 0, -_mm(1.2), 0, _mm(1.2));
    _appendBlock(c, version, 'HZ_POLE', b.toString());
    c.sb.write('0\nENDSEC\n');
  }

  static void _appendBlock(
      _Ctx c, DxfVersion version, String name, String body) {
    if (version == DxfVersion.r2000) {
      c.sb.write('0\nBLOCK\n5\n${c.h.next()}\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockBegin\n2\n$name\n70\n0\n'
          '10\n0.000\n20\n0.000\n30\n0.000\n3\n$name\n1\n\n');
    } else {
      c.sb.write('0\nBLOCK\n8\n0\n2\n$name\n70\n0\n10\n0\n20\n0\n30\n0\n3\n$name\n');
    }
    c.sb.write(body);
    if (version == DxfVersion.r2000) {
      c.sb.write('0\nENDBLK\n5\n${c.h.next()}\n330\n0\n100\nAcDbEntity\n8\n0\n'
          '100\nAcDbBlockEnd\n');
    } else {
      c.sb.write('0\nENDBLK\n8\n0\n');
    }
  }

  static void _appendInsert(
      _Ctx c, String layer, String name, double x, double y,
      {double sx = 1, double sy = 1}) {
    c.ent('INSERT', layer, 'AcDbBlockReference');
    c.sb.write('2\n$name\n'
        '10\n${_fmt(x)}\n20\n${_fmt(y)}\n30\n0\n'
        '41\n${_fmt(sx)}\n42\n${_fmt(sy)}\n50\n0\n');
  }

  // ================= 配线图（DXF 内自动生成） =================

  /// 配线图（设计院沿线画法，可选附加）：把杆路主干拉直成水平主线（里程轴），
  /// 箱体按其在主干上的投影里程挂在主线上方，分支深度决定纵向层级。
  /// 超过 500m 自动分图幅（每幅一条主线，纵向堆叠），返回绘图范围
  /// [maxX, minY, maxY]（本地坐标，供整体包围盒扩展）。
  static List<double> _appendWiringDiagram(
      _Ctx c,
      List<MapLabel> labels,
      double ox,
      double oyTop,
      double baseLon,
      double baseLat,
      double scaleX,
      double scaleY,
      DxfVersion version,
      int ps) {
    final roots = Topology.buildTree(labels);
    Topology.assignTitles(roots);
    final nodes = Topology.flatten(roots);

    // ---- 1. 主链提取：按 lineGroupId 建索引，取累计长度最长的一条链作主干 ----
    final groups = <String, List<MapLabel>>{};
    for (final l in labels) {
      if (l.lineGroupId.isEmpty) continue;
      groups.putIfAbsent(l.lineGroupId, () => []).add(l);
    }
    var trunk = <MapLabel>[];
    var trunkLen = 0.0;
    for (final g in groups.values) {
      if (g.length < 2) continue;
      if (g.every(_isTrackPoint)) continue; // 轨迹链不当杆路主干
      var len = 0.0;
      for (var i = 1; i < g.length; i++) {
        len += _segDistance(g[i - 1], g[i]);
      }
      if (len > trunkLen) {
        trunkLen = len;
        trunk = g;
      }
    }
    if (trunk.length < 2) trunk = labels; // 兜底：无连线时全部点当主干

    // ---- 2. 主干里程：沿主链累计每杆里程（段距优先 distLabel，否则 haversine）----
    final cumMile = <double>[0.0];
    final trunkCart = <List<double>>[];
    for (var i = 0; i < trunk.length; i++) {
      final l = trunk[i];
      trunkCart.add([
        (l.lon - baseLon) * scaleX,
        (l.lat - baseLat) * scaleY,
      ]);
      if (i > 0) {
        cumMile.add(cumMile[i - 1] + _segDistance(trunk[i - 1], trunk[i]));
      }
    }

    // ---- 3. 箱体节点投影到主干：里程 → 横坐标 X，分支深度 → 纵向层级 ----
    for (final n in nodes) {
      var d = 0;
      for (var p = n.parent; p != null; p = p.parent) {
        d++;
      }
      n.y = d.toDouble();
      final p0 = [
        (n.src.lon - baseLon) * scaleX,
        (n.src.lat - baseLat) * scaleY,
      ];
      final proj = _projectOnChain(p0, trunkCart, cumMile);
      // 垂距阈值 200 **真实米**（_projectOnChain 返回的是米制距离）
      if (proj[1] <= 200) {
        n.x = proj[0];
      } else {
        n.x = n.parent?.x ?? 0;
      }
    }

    // ---- 4. 分图幅：每幅 500m（真实里程），纵向堆叠间距 45m ----
    // 注意：里程轴单位是**真实米**，落图时统一乘 1/ps 转成模型单位。
    const bandW = 500.0;
    final km2u = _geo(1.0, ps); // 米 → 模型单位
    final totalMile = cumMile.isEmpty ? 0.0 : cumMile.last;
    final bandCount = math.max(1, (totalMile / bandW).ceil());
    var extMaxX = ox + bandW * km2u,
        extMinY = oyTop - 30 * km2u,
        extMaxY = oyTop;

    for (var band = 0; band < bandCount; band++) {
      final xs = band * bandW;
      final xe = math.min(totalMile, xs + bandW);
      final mainY = oyTop - 25 * km2u - band * 45 * km2u;
      // 主干粗线（按幅裁剪，宽 0.6mm 纸面）
      final clipped = _clipChainByMile(trunkCart, cumMile, xs, xe);
      if (clipped.length >= 2) {
        final pts = [
          for (final p in clipped)
            // p 是链上笛卡尔（模型单位），xs 是里程（米）→ 里程也要换算
            [ox + p[0] - xs * km2u, mainY]
        ];
        _appendPolyline(c, 'PeiXianTu', pts, width: _mm(0.6), version: version);
      }
      // 沿线每杆位置画小刻度短线（±2mm 纸面）
      for (var i = 0; i < trunkCart.length; i++) {
        final mi = cumMile[i];
        if (mi < xs || mi > xe) continue;
        final x = ox + mi * km2u - xs * km2u;
        _appendLine(c, 'PeiXianTu', x, mainY - _mm(2.0),
            x, mainY + _mm(2.0));
      }
      // 图幅分幅线与标注
      if (bandCount > 1) {
        _text(c, 'PeiXianTu', ox, mainY + _mm(8.0), _mm(3.0),
            '第 ${band + 1}/$bandCount 幅（K${(xs / 1000).toStringAsFixed(1)}-K${(xe / 1000).toStringAsFixed(1)}）');
      }

      // 本幅内的箱体
      final inBand = nodes.where((n) => n.x >= xs && n.x <= xe).toList();
      // 防重叠：同深度按 X 排序，相邻间距 ≥ 20m；父 X ≤ 子 X - 10
      final byDepth = <int, List<TopoNode>>{};
      for (final n in inBand) {
        byDepth.putIfAbsent(n.y.toInt(), () => []).add(n);
      }
      for (final d in byDepth.keys) {
        final list = byDepth[d]!..sort((a, b) => a.x.compareTo(b.x));
        for (final n in list) {
          final p = n.parent;
          if (p != null && n.x < p.x + 10) n.x = p.x + 10;
        }
        for (var i = 1; i < list.length; i++) {
          if (list[i].x < list[i - 1].x + 20) list[i].x = list[i - 1].x + 20;
        }
      }

      // 箱体：挂接虚线 + 符号 + 名称/分光比
      for (final n in inBand) {
        final x = ox + n.x * km2u - xs * km2u;
        final y = mainY + 15 * km2u * n.y;
        if (n.y >= 1) {
          _appendDashedVLine(
              c, 'PeiXianTu', x, mainY + km2u, y - 2.2 * km2u);
        }
        // 兜底同上：箱体非分光器/光交等一律按槽位箱
        final nlt = LabelType.fromId(n.src.typeId);
        final nisFb = n.src.typeId == 'fiberbox' ||
            n.src.typeId == 'fdcab' ||
            n.src.typeId == 'termbox' ||
            n.src.name.contains('分纤') ||
            (nlt.isBox &&
                n.src.typeId != 'splitterbox' &&
                n.src.typeId != 'crossbox' &&
                n.src.typeId != 'onubox' &&
                n.src.typeId != 'room' &&
                n.src.typeId != 'bts');
        _appendInsert(c, 'PeiXianTu', nisFb ? 'HZ_FIBERBOX' : 'HZ_BOX', x, y);
        _appendTextCentered(
            c, 'PeiXianTu', x, y + _mm(2.6), _mm(2.8), n.title);
        if (n.sub.isNotEmpty) {
          _appendTextCentered(
              c, 'PeiXianTu', x, y - _mm(3.6), _mm(2.4), n.sub);
        }
        final note = n.src.note.trim();
        if (note.isNotEmpty) {
          _appendTextCentered(
              c, 'PeiXianTu', x, y - _mm(6.4), _mm(2.4), note);
        }
      }

      // 父子连线（同幅内才画）：竖-横-竖直角线，段上标注距离与光缆型号
      for (final n in inBand) {
        final p = n.parent;
        if (p == null) continue;
        if (p.x < xs || p.x > xe) continue; // 父在邻幅：跳过（避免跨幅乱线）
        final px = ox + p.x * km2u - xs * km2u,
            pyTop = mainY + 15 * km2u * p.y - 2.2 * km2u;
        final cx = ox + n.x * km2u - xs * km2u,
            cyTop = mainY + 15 * km2u * n.y + 2.2 * km2u;
        final midY = (pyTop + cyTop) / 2;
        if ((cx - px).abs() < 1e-6) {
          _appendLine(c, 'PeiXianTu', px, pyTop, cx, cyTop);
        } else {
          _appendLine(c, 'PeiXianTu', px, pyTop, px, midY);
          _appendLine(c, 'PeiXianTu', px, midY, cx, midY);
          _appendLine(c, 'PeiXianTu', cx, midY, cx, cyTop);
        }
        final dist = _haversine(p.src.lat, p.src.lon, n.src.lat, n.src.lon);
        _text(c, 'PeiXianTu', cx + _mm(2.0), midY + _mm(1.2), _mm(2.5),
            dist.toStringAsFixed(1), style: true);
        if (n.cable.isNotEmpty) {
          _text(c, 'PeiXianTu', cx + _mm(2.0), midY - _mm(2.2), _mm(2.5),
              n.cable, style: true);
        }
      }

      if (ox + bandW * km2u > extMaxX) extMaxX = ox + bandW * km2u;
      final bandBottom = mainY - 15 * km2u;
      if (bandBottom < extMinY) extMinY = bandBottom;
    }

    return [extMaxX, extMinY, extMaxY];
  }

  /// 把折线链按里程区间 [xs, xe] 裁剪，端点处线性插值。
  /// 返回 [起始里程, 途经里程…, 结束里程] 对应的链上点序列。
  static List<List<double>> _clipChainByMile(List<List<double>> chainPts,
      List<double> cumMile, double xs, double xe) {
    if (chainPts.isEmpty) return [];
    List<double> lerp(double mile) {
      for (var i = 1; i < chainPts.length; i++) {
        if (cumMile[i] >= mile) {
          final span = cumMile[i] - cumMile[i - 1];
          final t = span > 1e-9 ? (mile - cumMile[i - 1]) / span : 0.0;
          return [
            chainPts[i - 1][0] + t * (chainPts[i][0] - chainPts[i - 1][0]),
            chainPts[i - 1][1] + t * (chainPts[i][1] - chainPts[i - 1][1]),
          ];
        }
      }
      return chainPts.last;
    }

    final out = <List<double>>[];
    if (cumMile.last < xs || cumMile.first > xe) return out;
    out.add(lerp(xs));
    for (var i = 0; i < chainPts.length; i++) {
      if (cumMile[i] > xs && cumMile[i] < xe) out.add(chainPts[i]);
    }
    out.add(lerp(xe));
    return out;
  }

  /// 段距（标注优先口径）——唯一实现见 [GeoUtil.segLenLabelFirst]。
  /// 原先本文件自带一份拷贝，与 csv / archive_book 的同名私有方法逐字相同却各自演化。
  static double _segDistance(MapLabel a, MapLabel b) =>
      GeoUtil.segLenLabelFirst(a, b);

  /// 点到折线链的最近投影：返回 [投影里程, 垂距(米)]。
  /// chainPts 为笛卡尔坐标，cumMile 为每点累计里程。
  static List<double> _projectOnChain(List<double> p,
      List<List<double>> chainPts, List<double> cumMile) {
    var bestDist = double.infinity, bestMile = 0.0;
    for (var i = 1; i < chainPts.length; i++) {
      final s = chainPts[i - 1], e = chainPts[i];
      final dx = e[0] - s[0], dy = e[1] - s[1];
      final len2 = dx * dx + dy * dy;
      var t = 0.0;
      if (len2 > 1e-9) {
        t = ((p[0] - s[0]) * dx + (p[1] - s[1]) * dy) / len2;
        t = t.clamp(0.0, 1.0);
      }
      final qx = s[0] + t * dx, qy = s[1] + t * dy;
      final dist =
          math.sqrt((p[0] - qx) * (p[0] - qx) + (p[1] - qy) * (p[1] - qy));
      if (dist < bestDist) {
        bestDist = dist;
        bestMile = cumMile[i - 1] + t * (cumMile[i] - cumMile[i - 1]);
      }
    }
    return [bestMile, bestDist];
  }

  /// 竖直细虚线（短线段手工断开模拟）：x 固定，从 y1 到 y2（y2 > y1）。
  /// 虚线节奏按**纸面毫米**（2mm 实 + 1.2mm 空）。
  static void _appendDashedVLine(_Ctx c, String layer,
      double x, double y1, double y2) {
    if (y2 <= y1) return;
    final dash = _mm(2.0), gap = _mm(1.2);
    var y = y1;
    while (y < y2) {
      final ye = math.min(y + dash, y2);
      _appendLine(c, layer, x, y, x, ye);
      y = ye + gap;
    }
  }

  /// 近似居中 TEXT：汉字按全宽、字母数字按半宽估宽。
  static void _appendTextCentered(_Ctx c, String layer,
      double cx, double cy, double h, String text) {
    if (text.isEmpty) return;
    var w = 0.0;
    for (final r in text.runes) {
      w += r > 0x2E7F ? h : h * 0.55;
    }
    _text(c, layer, cx - w / 2, cy - h * 0.35, h, text);
  }

  // ---- 通用 ----

  static bool _isTrackPoint(MapLabel label) =>
      label.typeId == 'track' || label.typeId == 'none';

  static double _haversine(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(la2 - la1);
    final dLon = rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(la1)) * math.cos(rad(la2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// DXF 段标注的距离数字：**不带单位**（图纸单位由图层设定，即米）。
  ///
  /// 直接委托 [GeoUtil.segDistText] —— 屏上段标与图纸段标必须是同一个字符串。
  /// 这里曾经自己写 `toStringAsFixed(1)`，于是 ≥1km 的长杆档在屏幕上写「埋1.05km」、
  /// 在图上写「埋1050.0」；随后又改成"自己调 stripDotZero 但保留 km 分支"，仍会分叉。
  /// 现在规则只剩一处，再想分叉也没有地方写了。
  static String _formatDistNoUnit(double m) => GeoUtil.segDistText(m);

  static double _pointToLineDistance(List<double> point, List<double> lineStart, List<double> lineEnd) {
    final double dx = lineEnd[0] - lineStart[0];
    final double dy = lineEnd[1] - lineStart[1];
    if (dx == 0 && dy == 0) {
      // lineStart and lineEnd are the same point
      return math.sqrt((point[0] - lineStart[0]) * (point[0] - lineStart[0]) +
          (point[1] - lineStart[1]) * (point[1] - lineStart[1]));
    }
    final double t = ((point[0] - lineStart[0]) * dx + (point[1] - lineStart[1]) * dy) /
        (dx * dx + dy * dy);
    final double projectionX = lineStart[0] + t * dx;
    final double projectionY = lineStart[1] + t * dy;
    final double dxProj = point[0] - projectionX;
    final double dyProj = point[1] - projectionY;
    return math.sqrt(dxProj * dxProj + dyProj * dyProj);
  }

  static List<List<double>> _simplifyPath(List<List<double>> points, double tolerance) {
    if (points.length < 3) {
      return List.from(points);
    }
    final List<bool> markers = List.filled(points.length, false);
    markers[0] = true;
    markers[points.length - 1] = true;

    _simplifyPathRecursive(points, markers, 0, points.length - 1, tolerance);

    final List<List<double>> result = <List<double>>[];
    for (int i = 0; i < points.length; i++) {
      if (markers[i]) {
        result.add(points[i]);
      }
    }
    return result;
  }

  static void _simplifyPathRecursive(
      List<List<double>> points,
      List<bool> markers,
      int startIndex,
      int endIndex,
      double tolerance) {
    double maxDistance = 0.0;
    int index = 0;
    final List<double> startPoint = points[startIndex];
    final List<double> endPoint = points[endIndex];
    for (int i = startIndex + 1; i < endIndex; i++) {
      final double distance = _pointToLineDistance(points[i], startPoint, endPoint);
      if (distance > maxDistance) {
        maxDistance = distance;
        index = i;
      }
    }
    if (maxDistance > tolerance) {
      markers[index] = true;
      _simplifyPathRecursive(points, markers, startIndex, index, tolerance);
      _simplifyPathRecursive(points, markers, index, endIndex, tolerance);
    }
  }

  // ==================== 表段 / 对象段（版本 gate） ====================

  /// 写 TABLES 段：图层表 + 文字样式表。
  /// - R2000：表头/记录均写句柄 `5` + 属主 `330` + 子类标记 `100 AcDb*`；
  ///   图层追加 `370`（线宽 1/100mm）与 `420`（真彩）。
  /// - R12：维持原样（仅 `62`/`6`，无句柄/子类标记）。
  /// 竣工红（completionRed）时杆路/管廊 ACI 改 1。
  static void _appendTables(
      _Ctx c, DxfVersion version, bool completionRed) {
    final specs = DxfLayers.resolve(completionRed: completionRed);
    c.sb.write('0\nSECTION\n2\nTABLES\n');
    if (version == DxfVersion.r2000) {
      final layerTableH = c.h.next();
      c.sb.write('0\nTABLE\n2\nLAYER\n5\n$layerTableH\n330\n0\n'
          '100\nAcDbSymbolTable\n70\n${specs.length}\n');
      for (final s in specs) {
        c.sb.write('0\nLAYER\n5\n${c.h.next()}\n330\n$layerTableH\n'
            '100\nAcDbSymbolTableRecord\n100\nAcDbLayerTableRecord\n'
            '2\n${s.name}\n70\n0\n62\n${s.aci}\n6\n${s.lineType}\n');
        c.sb.write('370\n${s.lineWeight}\n');
        if (s.trueColor != null) c.sb.write('420\n${s.trueColor}\n');
      }
      c.sb.write('0\nENDTAB\n');
      // 线型表：DASHED（拆除层用虚线）。
      final ltypeTableH = c.h.next();
      c.sb.write('0\nTABLE\n2\nLTYPE\n5\n$ltypeTableH\n330\n0\n'
          '100\nAcDbSymbolTable\n70\n1\n');
      c.sb.write('0\nLTYPE\n5\n${c.h.next()}\n330\n$ltypeTableH\n'
          '100\nAcDbSymbolTableRecord\n100\nAcDbLinetypeTableRecord\n'
          '2\nDASHED\n70\n0\n3\n__ __ \n72\n65\n73\n2\n40\n0.75\n'
          '49\n0.5\n49\n-0.25\n');
      c.sb.write('0\nENDTAB\n');
      final styleTableH = c.h.next();
      c.sb.write('0\nTABLE\n2\nSTYLE\n5\n$styleTableH\n330\n0\n'
          '100\nAcDbSymbolTable\n70\n2\n');
      c.sb.write('0\nSTYLE\n5\n${c.h.next()}\n330\n$styleTableH\n'
          '100\nAcDbSymbolTableRecord\n100\nAcDbTextStyleTableRecord\n'
          '2\nSimSun\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n'
          '3\nSimSun.ttf\n4\n\n');
      // 路名专用宋体样式（ASCII 样式名避免编码问题；fontFile=宋体 simsun.ttc）。
      // 仅 DaoLu 层路名 TEXT 引用，其他文字样式保持不变。
      c.sb.write('0\nSTYLE\n5\n${c.h.next()}\n330\n$styleTableH\n'
          '100\nAcDbSymbolTableRecord\n100\nAcDbTextStyleTableRecord\n'
          '2\nSongTi\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n'
          '3\nsimsun.ttc\n4\n\n');
      c.sb.write('0\nENDTAB\n0\nENDSEC\n');
    } else {
      c.sb.write('0\nTABLE\n2\nLAYER\n70\n${specs.length}\n');
      for (final s in specs) {
        c.sb.write('0\nLAYER\n2\n${s.name}\n70\n0\n62\n${s.aci}\n6\n${s.lineType}\n');
      }
      c.sb.write('0\nENDTAB\n');
      // 线型表：DASHED（拆除层用虚线）。
      c.sb.write('0\nTABLE\n2\nLTYPE\n70\n1\n');
      c.sb.write('0\nLTYPE\n2\nDASHED\n70\n0\n3\n__ __ \n72\n65\n73\n2\n'
          '40\n0.75\n49\n0.5\n49\n-0.25\n');
      c.sb.write('0\nENDTAB\n');
      c.sb.write('0\nTABLE\n2\nSTYLE\n70\n2\n');
      c.sb.write('0\nSTYLE\n2\nSimSun\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n3\nSimSun.ttf\n4\n\n');
      c.sb.write('0\nSTYLE\n2\nSongTi\n70\n0\n40\n0\n41\n1\n50\n0\n71\n0\n42\n3\n3\nsimsun.ttc\n4\n\n');
      c.sb.write('0\nENDTAB\n0\nENDSEC\n');
    }
  }

  /// OBJECTS 段（R2000 必需）：根命名对象字典 + ACAD_GROUP 子字典。
  static void _appendObjectsSection(_Ctx c) {
    final root = c.h.next();
    final group = c.h.next();
    c.sb.write('0\nSECTION\n2\nOBJECTS\n');
    c.sb.write('0\nDICTIONARY\n5\n$root\n330\n0\n100\nAcDbDictionary\n281\n1\n'
        '3\nACAD_GROUP\n350\n$group\n');
    c.sb.write('0\nDICTIONARY\n5\n$group\n330\n$root\n100\nAcDbDictionary\n281\n1\n');
    c.sb.write('0\nENDSEC\n');
  }

  // ==================== 底图渲染（T3） ====================

  /// 渲染底图（建筑填充(可选)→建筑轮廓→道路双线描边→路名→地名），文字统一后置输出。
  /// 返回底图几何的整体包围盒 `[minX, minY, maxX, maxY]`（供图框扩展）。
  ///
  /// **所有线宽/字号按纸面毫米换算（见 [_mm]），与出图比例无关。**
  static List<double>? _appendBasemap(
    _Ctx c,
    BasemapData bm,
    DxfVersion version, {
    required double baseLon,
    required double baseLat,
    required double scaleX,
    required double scaleY,
    required int ps, // 出图比例：米制容差 → 模型单位的换算用
    required bool layerRoads,
    required bool layerBuildingOutline,
    required bool buildingFill,
    required bool showMinorRoadNames,
    required bool layerPlaces,
  }) {
    final acc = _Ext(double.infinity, double.infinity, -double.infinity,
        -double.infinity);
    // 文字后置：使底图注记压在底图几何之上（CAD 中后画者在上层）。
    // 注意：整段底图（含其文字）都先于业务层写出，故业务层仍整体置顶（P0-5）。
    // 底图文字缓冲与主体共用句柄分配器（c.h），避免重复句柄。
    final labelBuf = StringBuffer();
    final lc = _Ctx(labelBuf, version, c.h);

    // —— 建筑（先填充成块、再轮廓；文字后置）——
    if (buildingFill || layerBuildingOutline) {
      final ringsPerBld = <List<List<List<double>>>>[];
      for (final b in bm.buildings) {
        final rings = _toCartRings(b, baseLon, baseLat, scaleX, scaleY);
        ringsPerBld.add(rings);
        for (final ring in rings) {
          for (final p in ring) {
            acc.add(p[0], p[1]);
          }
        }
      }
      if (buildingFill) {
        for (final rings in ringsPerBld) {
          if (rings.isEmpty) continue;
          _appendBuildingFill(c, rings, version);
        }
      }
      if (layerBuildingOutline) {
        for (var i = 0; i < ringsPerBld.length; i++) {
          final rings = ringsPerBld[i];
          for (final ring in rings) {
            if (ring.length >= 3) {
              _appendPolyline(c, 'JianZhu', ring,
                  closed: true, version: version);
            }
          }
          final b = bm.buildings[i];
          if (b.name.isNotEmpty && rings.isNotEmpty) {
            final o = rings.first;
            var cx = 0.0, cy = 0.0;
            for (final p in o) {
              cx += p[0];
              cy += p[1];
            }
            cx /= o.length;
            cy /= o.length;
            final h = _mm(2.5); // 建筑名 2.5mm（字高规范）
            _appendTextCentered(lc, 'JianZhu', cx, cy, h, b.name);
          }
        }
      }
    }

    // —— 道路（双线描边，按等级分级；交叉口开口+倒角；路名居中标注可按等级过滤）——
    if (layerRoads) {
      // 两阶段：先收集全部道路中心线 → 统一交叉口处理 → 再绘制。
      // （交叉口需要全局视野：主路贯通、次路开口退让、倒角连接。）
      final jroads = <JunctionRoad>[];
      final rpList = <RoadPoly>[];
      for (final r in bm.roads) {
        final cart = <List<double>>[
          for (final p in r.pts)
            [(p[1] - baseLon) * scaleX, (p[0] - baseLat) * scaleY]
        ];
        // 简化容差：表值是**真实米**，须换算到模型单位才能与 cart 同尺度
        final simp = _simplifyPath(cart, _roadTolM(r.grade) / ps);
        if (simp.length < 2) continue;
        jroads.add(JunctionRoad(simp, r.grade, _roadHalfWidth(r.grade)));
        rpList.add(r);
      }
      // 交叉口倒角腿长：纸面 1.5mm（45° 真倒角，视觉上明确可辨）。
      final jres = RoadJunction.process(jroads, _mm(1.5));
      for (var i = 0; i < jroads.length; i++) {
        final rp = rpList[i];
        final halfW = jroads[i].halfW;
        for (final piece in jres.pieces[i]) {
          if (piece.length < 2) continue;
          _appendRoadPieceDual(c, piece, halfW, version);
          for (final p in piece) {
            acc.add(p[0], p[1]);
          }
          // 路名等级过滤：只过滤注记，**几何（DaoLuBian）一律保留**。
          final isMajor = switch (rp.grade) {
            RoadGrade.trunk ||
            RoadGrade.primary ||
            RoadGrade.secondary ||
            RoadGrade.tertiary ||
            RoadGrade.residential =>
              true,
            RoadGrade.service || RoadGrade.other => false,
          };
          // 路名按截断后的 piece 独立排布（不穿过交叉口）；
          // 过短的桩间不注记（60 **真实米**，须换算到模型单位）。
          if (rp.name.isNotEmpty &&
              (isMajor || showMinorRoadNames) &&
              _polyLen(piece) >= _geo(60.0, ps)) {
            _appendRoadName(lc, rp.name, piece, rp.grade, halfW, ps);
          }
        }
      }
      // 交叉口倒角线
      for (final ch in jres.chamfers) {
        _appendLine(c, 'DaoLuBian', ch[0][0], ch[0][1], ch[1][0], ch[1][1]);
      }
    }

    // —— 周边要素：电力线（DianLi，橙）/ 水系沟渠（ShuiXi，蓝）——
    // 通信线路设计必须与电力杆线的交越/平行关系一起看，过河过沟也要有参照。
    if (bm.extras.isNotEmpty) {
      for (final e in bm.extras) {
        final layer = e.kind == 'power' ? 'DianLi' : 'ShuiXi';
        final pts = <List<double>>[];
        for (final pt in e.pts) {
          pts.add([(pt[1] - baseLon) * scaleX, (pt[0] - baseLat) * scaleY]);
        }
        if (pts.length >= 2) {
          _appendPolyline(c, layer, pts, version: version);
          for (final q in pts) {
            acc.add(q[0], q[1]);
          }
        }
      }
    }

    // —— 地名（DiMing 层，字号按级别）——
    if (layerPlaces) {
      for (final p in bm.places) {
        final x = (p.lon - baseLon) * scaleX;
        final y = (p.lat - baseLat) * scaleY;
        _appendTextCentered(lc, 'DiMing', x, y,
            _mm(_placeFontMm(p.level)), p.name);
        acc.add(x, y);
      }
    }

    // 底图内部文字统一后置输出（底图几何之上；整体仍先于业务层写出）
    c.sb.write(labelBuf.toString());

    if (acc.minX > acc.maxX || acc.minY > acc.maxY) return null;
    return [acc.minX, acc.minY, acc.maxX, acc.maxY];
  }

  /// 单段道路中心线的双线描边（已做交叉口截断，直接绘制）。
  static void _appendRoadPieceDual(
    _Ctx c,
    List<List<double>> piece,
    double halfW,
    DxfVersion version,
  ) {
    if (halfW > 1e-6) {
      final left = _offsetPolyline(piece, halfW);
      final right = _offsetPolyline(piece, -halfW);
      if (left.length >= 2) {
        _appendPolyline(c, 'DaoLuBian', left, version: version);
      }
      if (right.length >= 2) {
        _appendPolyline(c, 'DaoLuBian', right, version: version);
      }
    }
  }

  /// 折线总长（模型单位）。
  static double _polyLen(List<List<double>> pts) {
    var t = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final dx = pts[i][0] - pts[i - 1][0], dy = pts[i][1] - pts[i - 1][1];
      t += math.sqrt(dx * dx + dy * dy);
    }
    return t;
  }

  /// 路名注记：**置于道路中心线上（即双线描边之间）**，字号 clamp 进双线间隙，
  /// 沿弧长每约 200 **真实米**一处（均匀分布），宋体（SongTi 样式），旋转不倒立。
  ///
  /// 间距取真实米而非纸面毫米：路名重复频率应与**道路实际长度**挂钩，
  /// 这样无论按 1:1000 还是 1:10000 出图，同一段路都保持"约每 200m 一个名"，
  /// 与图纸比例无关（这与字号/线宽的处理不同——那两项按纸面毫米，才对）。
  static void _appendRoadName(_Ctx lc, String name,
      List<List<double>> pts, RoadGrade grade, double halfW, int ps) {
    // 字号 clamp：必须放得进双线之间（0.6 系数留上下空隙）
    final h = math.min(_roadLabelM(grade), 2 * halfW * 0.6);
    // clamp 后纸面高度下限：低于最小可读高度则该路不标注（塞不下，硬塞会糊）。
    if (h < _mm(0.10)) return;
    var totalLen = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final dx = pts[i][0] - pts[i - 1][0];
      final dy = pts[i][1] - pts[i - 1][1];
      totalLen += math.sqrt(dx * dx + dy * dy);
    }
    if (totalLen < 1e-6) return;
    // 每约 200 真实米一处：n 处均匀分布，第 i 处（i=1..n）在弧长
    // totalLen*(2i-1)/(2n)（n=1 时正好中点）。总长是模型单位，故间距要换算。
    final labelGap = _geo(200.0, ps);
    final n = math.max(1, (totalLen / labelGap).round());
    var walked = 0.0; // 已走过弧长
    var idx = 1;
    for (var i = 1; i < pts.length && idx <= n; i++) {
      final s = pts[i - 1];
      final e = pts[i];
      final dx = e[0] - s[0], dy = e[1] - s[1];
      final segLen = math.sqrt(dx * dx + dy * dy);
      while (idx <= n) {
        final target = totalLen * (2 * idx - 1) / (2 * n);
        if (target > walked + segLen) break;
        final t = segLen > 1e-9 ? (target - walked) / segLen : 0.0;
        final px = s[0] + dx * t;
        final py = s[1] + dy * t;
        // 旋转不倒立：>90 或 <-90 时 +180（沿用既有逻辑）
        var angle = math.atan2(dy, dx) * 180 / math.pi;
        if (angle > 90 || angle < -90) angle += 180;
        _text(lc, 'DaoLu', px, py, h, name, angle: angle, styleName: 'SongTi');
        idx++;
      }
      walked += segLen;
    }
  }

  /// 建筑环 → 笛卡尔坐标环（丢弃 <3 点的环）。
  static List<List<List<double>>> _toCartRings(BuildingPoly b, double baseLon,
      double baseLat, double scaleX, double scaleY) {
    final out = <List<List<double>>>[];
    for (final ring in b.rings) {
      if (ring.length < 3) continue;
      out.add([
        for (final p in ring) [(p[1] - baseLon) * scaleX, (p[0] - baseLat) * scaleY]
      ]);
    }
    return out;
  }

  /// 建筑填充：R2000=`HATCH`（SOLID 图案，外环+孔）；R12=`SOLID` 三角近似（忽略孔）。
  static void _appendBuildingFill(_Ctx c,
      List<List<List<double>>> rings, DxfVersion version) {
    if (rings.isEmpty) return;
    final outer = rings.first;
    if (outer.length < 3) return;
    if (version == DxfVersion.r2000) {
      _appendHatch(c, 'JianZhuFill', rings);
    } else {
      _appendSolidFill(c, outer);
    }
  }

  /// R2000 HATCH（SOLID 图案）：以各环为多段线边界路径写入 `JianZhuFill`。
  static void _appendHatch(
      _Ctx c, String layer, List<List<List<double>>> rings) {
    final paths = <List<List<double>>>[
      for (final r in rings)
        if (r.length >= 3) r
    ];
    if (paths.isEmpty) return;
    c.ent('HATCH', layer, 'AcDbHatch');
    c.sb.write('62\n7\n2\nSOLID\n'
        '70\n1\n71\n0\n91\n${paths.length}\n');
    for (final path in paths) {
      // 92=7（External|Polyline|Derived），72=无凸度，73=闭合，93=顶点数
      c.sb.write('92\n7\n72\n0\n73\n1\n93\n${path.length}\n');
      for (final p in path) {
        c.sb.write('10\n${_fmt(p[0])}\n20\n${_fmt(p[1])}\n');
      }
      c.sb.write('97\n0\n');
    }
    c.sb.write('75\n0\n76\n1\n');
  }

  /// R12 SOLID 三角近似填充（耳切三角化，逐三角形写 SOLID 四顶点实体）。
  static void _appendSolidFill(_Ctx c, List<List<double>> ring) {
    for (final t in _triangulate(ring)) {
      if (t.length < 3) continue;
      _appendSolidTri(c, 'JianZhuFill', t[0], t[1], t[2]);
    }
  }

  /// 单个三角形 → SOLID（10/11/12 为三顶点，13 取第 3 点成退化四边形）。
  static void _appendSolidTri(_Ctx c, String layer,
      List<double> a, List<double> b, List<double> d) {
    c.ent('SOLID', layer, 'AcDbTrace');
    c.sb.write('10\n${_fmt(a[0])}\n20\n${_fmt(a[1])}\n30\n0\n'
        '11\n${_fmt(b[0])}\n21\n${_fmt(b[1])}\n31\n0\n'
        '12\n${_fmt(d[0])}\n22\n${_fmt(d[1])}\n32\n0\n'
        '13\n${_fmt(d[0])}\n23\n${_fmt(d[1])}\n33\n0\n');
  }

  /// 多边形耳切三角化（自研纯 Dart）：先归一到逆时针，再逐耳裁出三角形。
  static List<List<List<double>>> _triangulate(List<List<double>> poly) {
    final pts = <List<double>>[];
    for (final p in poly) {
      if (pts.isEmpty || _dist2(pts.last, p) > 1e-12) pts.add(p);
    }
    if (pts.length >= 2 && _dist2(pts.first, pts.last) < 1e-12) {
      pts.removeLast();
    }
    final n = pts.length;
    if (n < 3) return const [];
    // 有向面积 → 统一为逆时针（凸顶点 cross > 0）
    var area2 = 0.0;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      area2 += pts[i][0] * pts[j][1] - pts[j][0] * pts[i][1];
    }
    final p2 = area2 < 0 ? pts.reversed.toList() : pts;
    final idx = List<int>.generate(n, (i) => i);
    final out = <List<List<double>>>[];
    var guard = 0;
    while (idx.length > 3 && guard < n * n) {
      guard++;
      var earFound = false;
      for (var i = 0; i < idx.length; i++) {
        final im = idx[(i - 1 + idx.length) % idx.length];
        final ic = idx[i];
        final ip = idx[(i + 1) % idx.length];
        final a = p2[im], b = p2[ic], cb = p2[ip];
        if (_cross(a, b, cb) <= 0) continue; // 凹顶点，跳过
        var contains = false;
        for (final k in idx) {
          if (k == im || k == ic || k == ip) continue;
          if (_inTri(p2[k], a, b, cb)) {
            contains = true;
            break;
          }
        }
        if (contains) continue;
        out.add([a, b, cb]);
        idx.removeAt(i);
        earFound = true;
        break;
      }
      if (!earFound) break; // 病态多边形：终止，保留已裁结果
    }
    if (idx.length == 3) {
      out.add([p2[idx[0]], p2[idx[1]], p2[idx[2]]]);
    }
    return out;
  }

  static double _cross(List<double> a, List<double> b, List<double> c) =>
      (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);

  static bool _inTri(List<double> p, List<double> a, List<double> b,
      List<double> c) {
    final d1 = _cross(a, b, p);
    final d2 = _cross(b, c, p);
    final d3 = _cross(c, a, p);
    final hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
    final hasPos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(hasNeg && hasPos);
  }

  static double _dist2(List<double> a, List<double> b) {
    final dx = a[0] - b[0], dy = a[1] - b[1];
    return dx * dx + dy * dy;
  }

  // ---- 比例换算（唯二入口，禁止再出现第三种写法）----

  /// **真实地面米 → DXF 模型单位**（几何专用）。
  ///
  /// 模型空间即缩小后的图纸：1 单位 = 1 纸面毫米 @ `plotScale`。
  /// 故 1:3000 时 50m 杆档 → 50/3000 = 0.01667 单位（纸面 16.67mm），量距正确。
  static double _geo(double realMeters, int plotScale) =>
      realMeters / plotScale;

  /// **纸面毫米 → DXF 模型单位**（图面元素专用：字高/线宽/符号/偏移）。
  ///
  /// 与 [plotScale] **无关**：因为模型单位本身就是纸面毫米。
  /// 2.5mm 字高 → 0.0025 单位，任何比例下视觉大小一致（这才是正规图纸该有的行为）。
  static double _mm(double paperMm) => paperMm / 1000.0;

  /// pin 类标签圆半径（纸面 2.5mm）。
  ///
  /// 旧实现 `_pinRadiusM(scale) = min(mm/1000*scale, 1.0)` 带 1.0 米上限，
  /// 是为了压制"比例跳档导致巨圆"的病态症状；比例统一后**上限不再需要**
  /// （0.0025 单位恒定），去掉它才能让杆符号在 1:3000 下是正常的 5mm 直径圆。
  static double _pinRadius() => _mm(2.5);

  static double _roadHalfWidth(RoadGrade g) =>
      _mm(_roadHalfWidthMm(g));
  static double _roadLabelM(RoadGrade g) => _mm(_roadLabelMm(g));

  /// 等级 → 半宽（纸面毫米）。
  /// 路宽（纸面毫米）：v3.9.5 放大一倍后用户仍反馈"有点窄"，
  /// 2026-10-01 起再整体放大一倍。
  static double _roadHalfWidthMm(RoadGrade g) => switch (g) {
        RoadGrade.trunk => 1.80,
        RoadGrade.primary => 1.52,
        RoadGrade.secondary => 1.20,
        RoadGrade.tertiary => 1.00,
        RoadGrade.residential => 0.72,
        RoadGrade.service => 0.48,
        RoadGrade.other => 0.40,
      };

  /// 等级 → 路名字号（纸面毫米）。
  static double _roadLabelMm(RoadGrade g) => switch (g) {
        RoadGrade.trunk => 2.0,
        RoadGrade.primary => 1.9,
        RoadGrade.secondary => 1.7,
        RoadGrade.tertiary => 1.5,
        RoadGrade.residential => 1.3,
        RoadGrade.service => 1.0,
        RoadGrade.other => 1.0,
      };

  /// 等级 → 简化容差（米，N4：主干细、小路粗）。
  static double _roadTolM(RoadGrade g) => switch (g) {
        RoadGrade.trunk => 0.5,
        RoadGrade.primary => 0.6,
        RoadGrade.secondary => 0.8,
        RoadGrade.tertiary => 1.0,
        RoadGrade.residential => 1.5,
        RoadGrade.service => 2.0,
        RoadGrade.other => 2.0,
      };

  /// 地名级别 → 字号（纸面毫米）。v4.0.2 起统一 2.5mm（用户要求），
  /// 不再分级——图面字高一致、干净。
  static double _placeFontMm(PlaceLevel _) => 2.5;
}
