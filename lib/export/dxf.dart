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
/// 坐标采用本地平面投影（以第一个点为原点，米为单位，等距圆柱近似，小范围足够）。
///
/// - **版本分支**收敛到 3 处：①图层表（R2000 写 `370`/`420`，R12 只写 `62`/`6`）；
///   ②多段线（R2000=`LWPOLYLINE`，R12=经典 `POLYLINE/VERTEX/SEQEND`）；
///   ③建筑填充（R2000=`HATCH`，R12=`SOLID` 三角近似）。**其余绘制逻辑完全共用**。
/// - **R2000 合法结构**：完整 HEADER（`$ACADVER/$HANDSEED/$EXTMIN/$EXTMAX/...`）+
///   CLASSES 段 + TABLES/BLOCKS 记录句柄 + 每个实体句柄(5) + `100 AcDb*` 子类标记 +
///   OBJECTS 段。**导出前后由 [DxfStructureValidator] 强校验**，校验不过即抛错，
///   绝不产出「打不开」的文件。
/// - **底图线宽/字号**一律按 `纸面毫米 ÷ 1000 × 出图比例` 换算为图纸米数，
///   不再 1:1 使用真实路宽（否则"路太粗/建筑塌陷"原样复发）。
/// - 业务层（杆路/管廊/桩号/距离/标签/配线图/图框）**行为保持不变**。
class DxfExporter {
  DxfExporter._();

  static String _fmt(double v) => v.toStringAsFixed(3);

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
  }) async {
    final warnings = <String>[];
    final dir = await LabelStore.instance.exportDir();
    final f = File('${dir.path}/${sanitizeName(name)}.dxf');

    if (labels.isEmpty) throw Exception('杆路为空');

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
      sb.write('9\n\$LIMMIN\n10\n0.000\n20\n0.000\n');
      sb.write('9\n\$LIMMAX\n10\n420.000\n20\n297.000\n');
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
    final scaleX = 111320.0 * math.cos(baseLat * math.pi / 180);
    const scaleY = 110540.0;

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
    // 线路-only 包络（改造注记定位、配线图尺寸用，不被底图外扩污染）
    final routeMinX = extMinX;
    final routeMinY = extMinY;
    final routeMaxX = extMaxX;
    final routeMaxY = extMaxY;

    // 改造工程量：新增/拆除长度分别统计（米），原有不计入
    var renoNewLenM = 0.0;
    var renoRemoveLenM = 0.0;
    // 人工光缆改造工程量（配线图连线）
    var fiberNewLenM = 0.0;
    var fiberRemoveLenM = 0.0;
    // 桩号跨线组连续累计：续画链/分支链不再从 K0+000 重新归零，
    // 全线桩号沿链输出顺序一杆接一杆递增（与竣工里程口径一致）。
    var globalCum = 0.0;

    // 图幅比例：**只按线路范围估算**（不被过大的底图外扩拖大），
    // 用于所有底图线宽/字号的「纸面毫米 → 图纸米」换算，图签亦报此比例（N5 修正）。
    final routeScale = _pickScale(extMinX, extMinY, extMaxX, extMaxY);
    // 字高按**纸面毫米**换算（v3.9.5）：此前直接写 2.5/3 被当作 2.5 米，
    // 图上极其巨大。用户要求：距离 2.5mm（宋体），其余与它和谐匹配。
    // v4.0.2 字高规范：常规注记 2.5mm，次要注记 2.0mm。
    final subFontM = _mmOf(2.0, routeScale);
    final labelFontM = _mmOf(2.5, routeScale);
    final noteFontM = _mmOf(2.0, routeScale);
    // pin 同步字高：圆内字、距离数字与 pin 圆同比例缩放（字高 = 圆半径）。
    // 道路名、小区/地名标识不参与同步，保持原纸面毫米尺寸。
    final pinFontM = _pinRadiusM(routeScale);

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
        routeScale,
        baseLon: baseLon,
        baseLat: baseLat,
        scaleX: scaleX,
        scaleY: scaleY,
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
      if (corridorWidth > 0) _appendCorridor(c, cart, corridorWidth, version);

      var chainCum = globalCum;
      // pin 类标签的圆半径（米）：线只连接到圆边，不穿过圆心
      final pinR = _pinRadiusM(routeScale);
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
        _text(c, 'JuLi', mx, my + 1.2, pinFontM, segText,
            angle: angle, style: true);
        // 盘留标注（段下方第一行）
        var extraY = my - 3.4;
        if (b.slackM > 0) {
          _text(c, 'JuLi', mx, extraY, subFontM, '盘留${_formatSlack(b.slackM)}m',
              angle: angle, style: true);
          extraY -= 2.6;
        }
        // 本段光缆型号（再下一行）
        if (b.segCable.trim().isNotEmpty) {
          _text(c, 'JuLi', mx, extraY, subFontM, b.segCable.trim(),
              angle: angle, style: true);
        }
        // 桩号：每杆位置标 K+里程（跨链连续；段距优先用人工确认值）
        if (showStakes) {
          if (i == 1) _appendStake(c, cart[0][0], cart[0][1], globalCum, routeScale);
          _appendStake(c, cart[i][0], cart[i][1], chainCum, routeScale);
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
      // 符号与文字同一坐标体系（对照通信工程图纸）：块基准 = 1:1000 纸面 mm，
      // 插入缩放 = routeScale/1000；文字偏移一律**纸面毫米**，不再用米。
      final symScale = routeScale / 1000.0;
      final offUpM = _mmOf(3.0, routeScale); // 名称在符号上方 3mm
      final offDownM = _mmOf(4.0, routeScale); // 孔数/附加在下方 4mm
      final offNoteM = _mmOf(6.0, routeScale); // 备注 6mm
      final offPhotoM = _mmOf(8.0, routeScale); // 照片数 8mm
      final holeDotsUpM = _mmOf(5.5, routeScale); // 芯线占用点 5.5mm
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
        // 分纤盒（纤）判定：用正规槽位箱符号（10×4.4），2026-10-08 用户要求
        // 兜底：箱体形状且非分光器/光交/ONU/机房/基站，一律按槽位箱画
        final isFb = lt.isBox &&
            (l.typeId == 'fiberbox' ||
                l.typeId == 'fdcab' ||
                l.typeId == 'termbox' ||
                l.name.contains('分纤') ||
                (l.typeId != 'splitterbox' &&
                    l.typeId != 'crossbox' &&
                    l.typeId != 'onubox' &&
                    l.typeId != 'room' &&
                    l.typeId != 'bts'));
        String block;
        if (lt.isOval) {
          block = 'HZ_OVAL';
        } else if (lt.isBox) {
          block = isFb ? 'HZ_FIBERBOX' : 'HZ_BOX';
        } else if (lt.isTri) {
          block = 'HZ_TRI';
        } else {
          block = 'HZ_POLE';
        }
        // pin 类 = 杆/管等（非 oval/box/tri）：圆圈 + 符号字在圆内。
        final isPin = !lt.isOval && !lt.isBox && !lt.isTri;
        if (lt.isBox || lt.isOval) {
          if (isFb) {
            // P1-16（2026-10-08 用户定版）：分纤盒永远标准 10×4.4 HZ_FIBERBOX，
            // 有名字也不按名字长度自适应画框；2槽/4槽仅"2槽位箱/4槽位箱"文字区分，
            // 与配线图画法一致。名字改注在符号上方（下方名字区，不再丢名）。
            _appendInsert(c, 'BiaoQian', 'HZ_FIBERBOX', x, y,
                sx: symScale, sy: symScale);
            _appendFiberBoxLabel(c, l, x, y, symScale, routeScale);
          } else if (disp.isNotEmpty) {
            var wChars = 0.0;
            for (final ch in disp.runes) {
              wChars += ch < 128 ? 0.55 : 1.0;
            }
            final textW = wChars * labelFontM;
            final boxW = textW + _mmOf(2.0, routeScale);
            final boxH = labelFontM + _mmOf(1.6, routeScale);
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
            // 非分纤盒的无名箱体/人孔：普通符号（分纤盒已在 isFb 分支处理）
            _appendInsert(c, 'BiaoQian', block, x, y, sx: symScale, sy: symScale);
          }
        } else if (isPin) {
          // pin 类（杆/管等）：圆圈 + 符号字在圆内（对齐地图样式；
          // 用户要求：圆内除字之外别无其他）。
          final rM = _pinRadiusM(routeScale);
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
          // 分纤盒的槽位箱文字已在符号分支画过，这里不再重复
          if (!isFb) _appendFiberBoxLabel(c, l, x, y, symScale, routeScale);
          continue;
        }
        // 箱体/人孔文字已在框内（上方入框画法）；pin 类符号字已在圆内，
        // 上方只注记点名（有名称才注）；引上（tri）保持符号/名称在上方。
        // 分纤盒（P1-16）：符号固定为 10×4.4 槽位箱，名字改注在符号上方。
        final pointName = l.name.trim();
        if (isPin) {
          if (pointName.isNotEmpty) {
            _text(c, 'BiaoQian', x, y + offUpM, labelFontM, pointName,
                style: true);
          }
        } else if (isFb) {
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
        // 拓扑异常不阻塞路由图导出（如节点数据不全），但必须让用户知道
        // （P0-7：此前空 catch，用户拿到"成功"的 DXF 却缺配线，会误判功能没生效）
        warnings.add('地理式配线（拓扑连线）绘制失败，已跳过：$e');
      }
    }

    // 配线图：2026-10-10 用户定版——走向与杆路图完全一致，只是整体缩小。
    // 数据源：手动光缆拓扑编辑器的 fiberLinks，或 ODN 拓扑图（topoParentId）。
    // 2026-10-10 补充：用户用 ODN 拓扑图而非手动编辑器时，fiberLinks 为空，
    // 需从 ODN 父子关系合成 FiberLink 再走新逻辑。
    var effectiveFiberLinks = fiberLinks;
    if (effectiveFiberLinks.isEmpty && hasTopo) {
      final byId = {for (final l in labels) l.id: l};
      final synth = <FiberLink>[];
      for (final l in labels) {
        final parent = l.topoParentId.isNotEmpty ? byId[l.topoParentId] : null;
        if (parent == null) continue;
        // P0-6：ODN 合成的连线必须带业务字段，否则新配线图的型号、
        // "长xx"、改造工程量标注全部缺失（用户主工作流）。
        // cableSpec 形如 "架24芯GYTS-01"：敷设前缀 → layMethod，
        // 芯数 → cores，剩余型号部分 → cableModel
        // （fullSpec 会自己拼 "N芯"，此处剥离避免 "48芯48芯GYTS"）。
        var cores =
            l.cableCores > 0 ? l.cableCores : Topology.parseCores(l.cableSpec);
        var lay = 0;
        var model = l.cableSpec.trim();
        const layPrefixes = {
          '架空': 1, '架': 1, //
          '管道': 2, '管': 2, //
          '埋地': 3, '直埋': 3, '埋': 3, //
          '引上': 4,
        };
        for (final e in layPrefixes.entries) {
          if (model.startsWith(e.key)) {
            lay = e.value;
            model = model.substring(e.key.length);
            break;
          }
        }
        if (cores > 0) {
          model = model.replaceFirst(RegExp('^$cores\\s*芯'), '');
        }
        synth.add(FiberLink(
          fromDeviceId: l.topoParentId,
          toDeviceId: l.id,
          cores: cores,
          cableModel: model.trim(),
          layMethod: lay,
          lengthM: _haversine(parent.lat, parent.lon, l.lat, l.lon),
          reno: l.reno,
        ));
      }
      if (synth.isNotEmpty) effectiveFiberLinks = synth;
    }
    final useNewWiring = effectiveFiberLinks.isNotEmpty;

    // 配线图（纯拓扑）：只画设备 + 光缆连线，走向沿路由、长度统一压缩，
    // 落点自动避让路由/底图/图例，不再把整条杆路缩小后压在路由图上。
    if (useNewWiring) {
      try {
        final topoIds = <String>{};
        for (final l in effectiveFiberLinks) {
          topoIds.add(l.fromDeviceId);
          topoIds.add(l.toDeviceId);
        }
        final topoDevices = [
          for (final d in labels)
            if (topoIds.contains(d.id)) d
        ];
        // 光缆改造工程量：只统计两端设备都在当前项目内的连线
        final deviceIds = {for (final d in topoDevices) d.id};
        for (final l in effectiveFiberLinks) {
          if (!deviceIds.contains(l.fromDeviceId) ||
              !deviceIds.contains(l.toDeviceId)) {
            continue;
          }
          if (l.reno == RenoState.added) {
            fiberNewLenM += l.lengthM;
          } else if (l.reno == RenoState.removed) {
            fiberRemoveLenM += l.lengthM;
          }
        }

        // 纸面口径：配线图最长边取路由的 18%，并限制在 35~55mm，
        // 既保证拓扑可读，又不把图幅撑出 A3；四周留白 15mm 容纳符号与文字。
        final routeSpanM = math.max(
            routeMaxX - routeMinX, routeMaxY - routeMinY);
        final targetSpanM = (routeSpanM * 0.18)
            .clamp(_mmOf(35, routeScale), _mmOf(55, routeScale))
            .toDouble();
        final layout = layoutWiringDiagram(
          topoDevices,
          effectiveFiberLinks,
          labels,
          targetSpanM: targetSpanM,
          padM: _mmOf(15, routeScale),
        );
        if (layout.nodes.isNotEmpty && layout.edges.isNotEmpty) {
          // 改造注记占线路下方约 16mm，配线图不得压它。
          final hasReno0 = renoNewLenM > 0 ||
              renoRemoveLenM > 0 ||
              fiberNewLenM > 0 ||
              fiberRemoveLenM > 0;
          final safeMinY = hasReno0
              ? math.min(extMinY, routeMinY - _mmOf(16, routeScale))
              : extMinY;
          // 图例在左下角，下置时右移让开。
          final origin = _pickWiringOrigin(
            extMinX,
            safeMinY,
            extMaxX,
            extMaxY,
            layout.width,
            layout.height,
            _mmOf(15, routeScale),
            showLegend ? _mmOf(55, routeScale) : 0.0,
          );
          final ox = origin[0], oy = origin[1];

          final symScale = routeScale / 1000.0; // 块基准 = 1:1000 纸面 mm
          final fontM = _mmOf(2.5, routeScale);
          final smallFontM = _mmOf(2.0, routeScale);
          final boxHalfW = 5.0 * symScale; // HZ_FIBERBOX 半宽
          const boxHalfH = 2.2; // HZ_FIBERBOX 半高（块单位）

          // 标题：一眼区分路由图与配线图
          _text(c, 'PeiXianTu', ox + _mmOf(2, routeScale),
              oy + _mmOf(3, routeScale), fontM, '配线图（拓扑）');

          // 光缆连线：沿压缩路由的折线（保留拐点），线宽 0.6mm
          for (final e in layout.edges) {
            _appendPolyline(
              c,
              'PeiXianTu',
              [
                for (final p in e.path) [ox + p.x, oy + p.y]
              ],
              width: _mmOf(0.6, routeScale),
              version: version,
            );
          }

          // 端点（无出边）：标成端处
          final hasOut = <String>{};
          for (final e in layout.edges) {
            hasOut.add(e.from.device.id);
          }

          for (final n in layout.nodes) {
            final cx = ox + n.x;
            final cy = oy + n.y;
            final lt = LabelType.fromId(n.device.typeId);
            // 纤箱判断：typeId 可能是 fiberbox/fdcab/termbox 或其他；
            // 兜底：箱体形状且非分光器/光交/ONU/机房/基站，一律按槽位箱画
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
            double halfH;
            if (isFiberBox) {
              // 符号与图面同口径：块 10×4.4 按 1:1000 纸面 mm 缩放
              _appendInsert(c, 'PeiXianTu', 'HZ_FIBERBOX', cx, cy,
                  sx: symScale, sy: symScale);
              halfH = boxHalfH * symScale;
              final slotText =
                  n.device.name.contains('4槽') ? '4槽位箱' : '2槽位箱';
              _text(c, 'PeiXianTu',
                  cx + boxHalfW + _mmOf(1.5, routeScale), cy, smallFontM,
                  slotText);
            } else {
              final hw = _mmOf(4.5, routeScale), hh = _mmOf(2.5, routeScale);
              halfH = hh;
              _appendRect(c, 'PeiXianTu', cx - hw, cy - hh, cx + hw, cy + hh);
            }
            // 设备名放符号上方居中，避免与右侧槽位文字互压
            _appendTextCentered(c, 'PeiXianTu', cx,
                cy + halfH + _mmOf(3.0, routeScale), fontM, n.label);
            // 成端处：符号下方居中
            if (!hasOut.contains(n.device.id)) {
              _appendTextCentered(c, 'PeiXianTu', cx,
                  cy - halfH - _mmOf(5.0, routeScale), smallFontM, '成端处');
            }
            // 分光器标注
            if (n.device.typeId == 'splitterbox') {
              final splitterInfo = n.device.note.contains('1:')
                  ? n.device.note
                  : n.device.name;
              if (splitterInfo.isNotEmpty) {
                _appendTextCentered(
                    c,
                    'PeiXianTu',
                    cx,
                    cy - halfH - _mmOf(9.0, routeScale),
                    smallFontM,
                    '分光器:$splitterInfo');
              }
            }
          }

          // 连线标注：型号在线上方、长度在线下方，随线段方向旋转
          for (final e in layout.edges) {
            final mid = _pathMid(e.path);
            final mx = ox + mid[0], my = oy + mid[1];
            final spec = e.link.fullSpec;
            if (spec.isNotEmpty) {
              _text(c, 'PeiXianTu', mx, my + _mmOf(2.0, routeScale),
                  smallFontM, spec, angle: mid[2]);
            }
            if (e.link.lengthM > 0) {
              _text(c, 'PeiXianTu', mx, my - _mmOf(4.5, routeScale),
                  smallFontM, '长${e.link.lengthM.toStringAsFixed(1)}',
                  angle: mid[2]);
            }
          }

          // 配线图整体并入图幅（layout 宽高已含四周留白）
          if (ox < extMinX) extMinX = ox;
          if (oy < extMinY) extMinY = oy;
          if (ox + layout.width > extMaxX) extMaxX = ox + layout.width;
          if (oy + layout.height > extMaxY) extMaxY = oy + layout.height;
        }
      } catch (e) {
        // 配线图异常不阻塞主图导出（P0-7：失败要进 warnings，不能静默缺图）
        warnings.add('配线图绘制失败，已跳过：$e');
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
      final renoH = _mmOf(10, routeScale) + _mmOf(6 * 2 + 4, routeScale);
      if (routeMinY - renoH < extMinY) extMinY = routeMinY - renoH;
    }

    // 图框（A3 幅面自动比例）+ 图例栏 + 指北针（对齐设计院图纸习惯）
    // 2026-10-05：删除标题栏（设计单位/工程名称图框），用户要求。
    _appendFrame(c, extMinX, extMinY, extMaxX, extMaxY);
    if (showLegend) {
      _appendLegend(c, labels, extMinX, extMinY, routeScale);
    }
    _appendNorthArrow(c, extMaxX, extMaxY);

    // 改造工程量注记（线路下方）：新增/拆除长度，无改造时不画
    // 2026-10-05：标题栏已删除，注记直接放在线路下方 10mm 处。
    final hasReno = renoNewLenM > 0 ||
        renoRemoveLenM > 0 ||
        fiberNewLenM > 0 ||
        fiberRemoveLenM > 0;
    if (hasReno) {
      final statFontM = _mmOf(3.0, routeScale);
      final sx = routeMaxX - _mmOf(120, routeScale);
      var sy = routeMinY - _mmOf(10, routeScale) - _mmOf(6, routeScale);
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
        sy -= _mmOf(6, routeScale);
      }
    }

    sb.write('0\nENDSEC\n');

    // OBJECTS 段（R2000 必需）：根命名对象字典 + ACAD_GROUP。
    if (version == DxfVersion.r2000) {
      _appendObjectsSection(c);
    }

    sb.write('0\nEOF\n');

    // 回填 R2000 HEADER 占位符（句柄种子 / 图幅范围）
    var text = sb.toString();
    if (version == DxfVersion.r2000) {
      text = text
          .replaceFirst('@@HANDSEED@@', h.nextValue.toRadixString(16).toUpperCase())
          .replaceFirst('@@EXTMINX@@', _fmt(extMinX))
          .replaceFirst('@@EXTMINY@@', _fmt(extMinY))
          .replaceFirst('@@EXTMAXX@@', _fmt(extMaxX))
          .replaceFirst('@@EXTMAXY@@', _fmt(extMaxY));
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

  /// 指北针：图框内右上角，圆 + N 字 + 指针三角。
  static void _appendNorthArrow(_Ctx c, double maxX, double maxY) {
    final cx = maxX - 14;
    final cy = maxY - 12;
    const r = 6.0;
    // 外圆（R12 直接输出 CIRCLE）
    c.ent('CIRCLE', 'BeiFangZhen', 'AcDbCircle');
    c.sb.write('10\n${_fmt(cx)}\n20\n${_fmt(cy)}\n30\n0\n40\n${_fmt(r)}\n');
    // 指针三角：尖朝上
    _appendTri(c, 'BeiFangZhen', cx, cy - 0.8, 2.4);
    // N 字
    _appendTextCentered(c, 'BeiFangZhen', cx, cy + r + 1.5, 3.5, 'N');
  }

  /// 配线图落点：在现有图幅（路由 + 底图 + 注记）外侧四个方位里，
  /// 取「扩幅后面积最小」的位置。四方位都与图幅保持 [gap] 间距，
  /// 天然不重叠；下置时右移 [legendW]，避开左下角图例。
  static List<double> _pickWiringOrigin(
      double minX,
      double minY,
      double maxX,
      double maxY,
      double w,
      double h,
      double gap,
      double legendW) {
    final cands = <List<double>>[
      [maxX + gap, minY], // 右
      [minX, maxY + gap], // 上
      [minX + legendW, minY - gap - h], // 下（避开图例）
      [minX - gap - w, maxY - h], // 左
    ];
    var best = cands.first;
    var bestArea = double.infinity;
    for (final c in cands) {
      final x0 = math.min(minX, c[0]);
      final y0 = math.min(minY, c[1]);
      final x1 = math.max(maxX, c[0] + w);
      final y1 = math.max(maxY, c[1] + h);
      final area = (x1 - x0) * (y1 - y0);
      if (area < bestArea) {
        bestArea = area;
        best = c;
      }
    }
    return best;
  }

  /// 折线按弧长取中点，并给出该处切线方向（度，规范到 -90..90 便于文字正读）。
  static List<double> _pathMid(List<math.Point<double>> ps) {
    if (ps.isEmpty) return const [0, 0, 0];
    var total = 0.0;
    for (var i = 1; i < ps.length; i++) {
      total += _segLen(ps[i - 1], ps[i]);
    }
    if (total < 1e-9) return [ps.first.x, ps.first.y, 0];
    final half = total / 2;
    var acc = 0.0;
    for (var i = 1; i < ps.length; i++) {
      final d = _segLen(ps[i - 1], ps[i]);
      if (d < 1e-9) continue;
      if (acc + d >= half) {
        final t = (half - acc) / d;
        final x = ps[i - 1].x + (ps[i].x - ps[i - 1].x) * t;
        final y = ps[i - 1].y + (ps[i].y - ps[i - 1].y) * t;
        var ang =
            math.atan2(ps[i].y - ps[i - 1].y, ps[i].x - ps[i - 1].x) *
                180 /
                math.pi;
        if (ang > 90) ang -= 180;
        if (ang < -90) ang += 180;
        return [x, y, ang];
      }
      acc += d;
    }
    final a = ps[ps.length - 2], b = ps.last;
    return [b.x, b.y, math.atan2(b.y - a.y, b.x - a.x) * 180 / math.pi];
  }

  static double _segLen(math.Point<double> a, math.Point<double> b) {
    final dx = b.x - a.x, dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// A3 图框：内容包围盒外加 10m 边距画边框。
  static void _appendFrame(_Ctx c, double minX,
      double minY, double maxX, double maxY) {
    const m = 10.0;
    final x0 = minX - m, y0 = minY - m;
    final x1 = maxX + m, y1 = maxY + m;
    _appendRect(c, 'TuQian', x0, y0, x1, y1);
  }

  /// 按 A3 幅面估算比例：**仅按线路包围盒** 较长边(米) ÷ 可打印宽(约 0.40m)，
  /// 向上对齐标准比例系列（1:100 … 1:10000）。
  /// 只用于"线路范围"（不被过大的底图外扩拖大），供底图线宽/字号换算与图签报告。
  ///
  /// **取 max(跨度X, 跨度Y) 作为内容尺寸**：南北向线路跨度 X≈0，若只看 X 会把比例
  /// 估到最小档，线宽/字号随之异常（O4 修正）；用较长边对横/纵两种走向都稳健。
  static int _pickScale(double minX, double minY, double maxX, double maxY) {
    const m = 10.0;
    final spanX = (maxX - minX).abs();
    final spanY = (maxY - minY).abs();
    final contentW = (math.max(spanX, spanY) + 2 * m).clamp(1.0, 1e9);
    final raw = contentW / 0.40;
    const std = [100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000];
    for (final s in std) {
      if (raw <= s) return s;
    }
    return (raw / 1000).ceil() * 1000;
  }

  /// 图例栏：图框内左下角，纵向排列本次用到的符号 + 类型名。
  ///
  /// P1-15：分纤盒用正规槽位箱符号 HZ_FIBERBOX（10×4.4，与图面一致），
  /// 不再一刀切 HZ_BOX；字高按纸面毫米换算（此前 3/2.5 裸米数）。
  static void _appendLegend(_Ctx c, List<MapLabel> labels,
      double minX, double minY, int routeScale) {
    final used = <String>{};
    for (final l in labels) {
      if (l.typeId == 'track' || l.typeId == 'none' || l.typeId == 'text') {
        continue;
      }
      used.add(l.typeId);
    }
    if (used.isEmpty) return;
    // 按 LabelType.all 的顺序输出，保持图例口径一致
    final ordered = LabelType.all.where((t) => used.contains(t.id)).toList();
    const m = 10.0;
    var y = minY - m + 4;
    final lx = minX - m + 4;
    final symScale = routeScale / 1000.0; // 块基准 = 1:1000 纸面 mm（与图面一致）
    _text(c, 'TuQian', lx, y + 6, _mmOf(3.0, routeScale), '图  例');
    for (final t in ordered) {
      String block;
      if (t.isOval) {
        block = 'HZ_OVAL';
      } else if (t.isBox) {
        // 与图面同口径：箱体形状且非分光器/光交/ONU/机房/基站 → 分纤盒符号
        final isFb = t.id == 'fiberbox' ||
            t.id == 'fdcab' ||
            t.id == 'termbox' ||
            (t.id != 'splitterbox' &&
                t.id != 'crossbox' &&
                t.id != 'onubox' &&
                t.id != 'room' &&
                t.id != 'bts');
        block = isFb ? 'HZ_FIBERBOX' : 'HZ_BOX';
      } else if (t.isTri) {
        block = 'HZ_TRI';
      } else {
        block = 'HZ_POLE';
      }
      // dot（水泥杆）：图例也画纯圆圈，与图面/地图一致，不再套 HZ_POLE（圆+十字）。
      if (t.shape == 'dot') {
        _appendCircle(c, 'TuQian', lx + 2, y, _pinRadiusM(routeScale));
      } else {
        _appendInsert(c, 'TuQian', block, lx + 2, y,
            sx: symScale, sy: symScale);
      }
      _text(c, 'TuQian', lx + 5, y - 1, _mmOf(2.5, routeScale), t.name);
      y -= 6;
    }
  }

  /// 桩号文字：K0+000 格式（千米 + 米，米保留 1 位小数）。字高 2.5mm 纸面。
  ///
  /// P0-8：字高/偏移一律按**纸面毫米**换算（同类修法见文件头注释）。
  /// 此前写裸米数（2.5/1.5/3.0），只在 routeScale=1000 时碰巧正确；
  /// 1:100 时字高 25mm 巨大、1:10000 时 0.25mm 看不见且压线。
  static void _appendStake(
      _Ctx c, double x, double y, double cum, int routeScale) {
    final km = cum ~/ 1000;
    final m = cum - km * 1000;
    final mStr = m.toStringAsFixed(1).padLeft(5, '0');
    _text(c, 'ZhuangHao', x + _mmOf(1.5, routeScale),
        y + _mmOf(3.0, routeScale), _mmOf(2.5, routeScale), 'K$km+$mStr');
  }

  /// 盘留数字格式：整数或 1 位小数。
  static String _formatSlack(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  /// 芯线/管孔占用可视化：一排小圆，已占用 = 圆内打叉，空闲 = 空心。
  /// 最多画 24 孔，避免一行拉太长。
  static void _appendFiberBoxLabel(
      _Ctx c, MapLabel l, double x, double y, double symScale, int routeScale) {
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
    final boxHalfW = 5.0 * symScale;
    _text(c, 'BiaoQian', x + boxHalfW + _mmOf(1.5, routeScale), y,
        _mmOf(2.5, routeScale), slotText);
  }

  static void _appendHoleDots(_Ctx c, double cx, double cy, MapLabel l) {
    final n = l.holes;
    if (n <= 0 || n > 24) return;
    const r = 0.7, gap = 2.0;
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

  /// 地理式配线（对齐手绘样图）：拓扑父子箱体在真实位置连粗黑线（宽 0.6），
  /// 沿线旋转标注箱体间距离与光缆型号；箱体上方挂标签牌（小矩形 + 名称），
  /// 牌下依次为分光比/孔数与备注。
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
    // P0-11：与新配线图口径统一——只画**显式** topoParentId 的边。
    // Topology.buildTree 还会按 seq 自动挂载无父节点的边（含显式 id 悬空/
    // 成环时的回退）；若把自动边也画出来，同一份数据在路由图 overlay 与
    // 配线图里就不是同一个拓扑。判定：树边的父 == 显式指定的父，才画。
    for (final n in nodes) {
      final p = n.parent;
      if (p == null) continue;
      if (n.src.topoParentId.isEmpty || p.src.id != n.src.topoParentId) continue;
      final p1 = pos[p.src.id]!, p2 = pos[n.src.id]!;
      // 粗黑折线（R2000=LWPOLYLINE / R12 经典 POLYLINE 常宽 0.6）
      _appendPolyline(c, 'PeiXianTu', [p1, p2],
          width: 0.6, version: version);
      final dx = p2[0] - p1[0], dy = p2[1] - p1[1];
      final len = math.sqrt(dx * dx + dy * dy);
      var angle = len > 1e-6 ? math.atan2(dy, dx) * 180 / math.pi : 0.0;
      if (angle > 90 || angle < -90) angle += 180;
      final dist = _haversine(p.src.lat, p.src.lon, n.src.lat, n.src.lon);
      final mx = (p1[0] + p2[0]) / 2, my = (p1[1] + p2[1]) / 2;
      // 距离放线上方，光缆型号放线下方
      _text(c, 'PeiXianTu', mx, my + 1.2, 2.5, dist.toStringAsFixed(1),
          angle: angle, style: true);
      if (n.cable.isNotEmpty) {
        _text(c, 'PeiXianTu', mx, my - 2.6, 2, n.cable,
            angle: angle, style: true);
      }
    }

    // 箱体标签牌（对齐手绘图上"2槽位箱"式小牌）：牌内为名称，
    // 牌下依次为分光比/孔数、备注
    for (final n in nodes) {
      final xy = pos[n.src.id]!;
      final x = xy[0], y = xy[1];
      final title = n.title;
      final tagW = title.length * 2.6 + 3.0;
      _appendRect(c, 'PeiXianTu', x - tagW / 2, y + 3.5, x + tagW / 2, y + 7);
      _appendTextCentered(c, 'PeiXianTu', x, y + 4.2, 2.2, title);
      if (n.sub.isNotEmpty) {
        _appendTextCentered(c, 'PeiXianTu', x, y - 4.2, 2.2, n.sub);
      }
      final note = n.src.note.trim();
      if (note.isNotEmpty) {
        _appendTextCentered(c, 'PeiXianTu', x, y - 6.8, 2.2, note);
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
    // 符号块基准尺寸 = **1:1000 出图比例下的纸面毫米值**（人孔 6×3.5mm、
    // 箱体 5×3mm、引上边 3mm、杆圆 r=1.2mm——通信工程制图惯例，符号远小
    // 于文字块、与字号协调）。插入时按 routeScale/1000 缩放（见符号循环）。
    _appendOval(bc, '0', 0, 0, 3.0, 1.75);
    _appendBlock(c, version, 'HZ_OVAL', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    _appendRect(bc, '0', -2.5, -1.5, 2.5, 1.5);
    _appendBlock(c, version, 'HZ_BOX', b.toString());
    // 正规槽位箱符号（2026-10-08 用户联通竣工图实测）：10.0×4.4 矩形，
    // 白色；2槽/4槽同尺寸，仅文字区分。专用于分纤盒（纤）。
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    _appendRect(bc, '0', -5.0, -2.2, 5.0, 2.2);
    _appendBlock(c, version, 'HZ_FIBERBOX', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    _appendTri(bc, '0', 0, 0, 1.5);
    _appendBlock(c, version, 'HZ_TRI', b.toString());
    b = StringBuffer();
    bc = _Ctx(b, version, c.h);
    bc.ent('CIRCLE', '0', 'AcDbCircle');
    bc.sb.write('10\n0\n20\n0\n30\n0\n40\n1.2\n');
    _appendLine(bc, '0', -1.2, 0, 1.2, 0);
    _appendLine(bc, '0', 0, -1.2, 0, 1.2);
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
  /// 返回底图几何的整体包围盒 `[minX, minY, maxX, maxY]`（供图框/图签扩展）。
  ///
  /// **所有线宽/字号均由「纸面毫米 ÷ 1000 × 出图比例 [scale]」换算为图纸米数。**
  static List<double>? _appendBasemap(
    _Ctx c,
    BasemapData bm,
    DxfVersion version,
    int scale, {
    required double baseLon,
    required double baseLat,
    required double scaleX,
    required double scaleY,
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
            final h = _mmOf(2.5, scale); // 建筑名 2.5mm（字高规范）
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
        final simp = _simplifyPath(cart, _roadTolM(r.grade));
        if (simp.length < 2) continue;
        jroads.add(JunctionRoad(simp, r.grade, _roadHalfWidthM(r.grade, scale)));
        rpList.add(r);
      }
      // 交叉口倒角腿长：纸面 1.5mm（45° 真倒角，视觉上明确可辨）。
      // 近miss容差 3m：兜底吸附后异名路口仍残留的小间隙。
      final jres =
          RoadJunction.process(jroads, _mmOf(1.5, scale), snapTol: 3.0);
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
          // 路名按截断后的 piece 独立排布（不穿过交叉口）；过短的桩间不注记。
          if (rp.name.isNotEmpty &&
              (isMajor || showMinorRoadNames) &&
              _polyLen(piece) >= 60) {
            _appendRoadName(lc, rp.name, piece, rp.grade, scale, halfW);
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
            _mmOf(_placeFontMm(p.level), scale), p.name);
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

  /// 折线总长（米）。
  static double _polyLen(List<List<double>> pts) {
    var t = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final dx = pts[i][0] - pts[i - 1][0], dy = pts[i][1] - pts[i - 1][1];
      t += math.sqrt(dx * dx + dy * dy);
    }
    return t;
  }

  /// 路名注记：**置于道路中心线上（即双线描边之间）**，字号 clamp 进双线间隙，
  /// 沿弧长每约 200 米一处（均匀分布），宋体（SongTi 样式），旋转不倒立。
  static void _appendRoadName(_Ctx lc, String name,
      List<List<double>> pts, RoadGrade grade, int scale, double halfW) {
    // 字号 clamp：必须放得进双线之间（0.6 系数留上下空隙）
    final h = math.min(_roadLabelM(grade, scale), 2 * halfW * 0.6);
    // clamp 后纸面高度下限：低于最小可读高度则该路不标注（塞不下，硬塞会糊）。
    // 注：现行分级半宽表下双线间隙最大 1.8mm（trunk），clamp 后字高最大 1.08mm，
    // 若按字面 1mm 阈值会把小路路名吞掉（与"尽量多保留路名"冲突），
    // 故取可读下限 0.10mm 纸面高度——仅病态窄路/未来表变更时兜底。
    if (h < _mmOf(0.10, scale)) return;
    var totalLen = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final dx = pts[i][0] - pts[i - 1][0];
      final dy = pts[i][1] - pts[i - 1][1];
      totalLen += math.sqrt(dx * dx + dy * dy);
    }
    if (totalLen < 1e-6) return;
    // 每约 200 米一处：n 处均匀分布，第 i 处（i=1..n）在弧长 totalLen*(2i-1)/(2n)
    //（n=1 时正好中点）
    final n = math.max(1, (totalLen / 200).round());
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

  // ---- 纸面毫米 → 图纸米（唯一换算入口）----

  static double _mmOf(double mm, int scale) => mm / 1000.0 * scale;

  /// pin 类标签圆半径（米）：纸面 2.5mm，但设 1.0m 上限。
  /// 根因（2026-10-05）：_mmOf(2.5, routeScale) 随线路跨度无上限膨胀——
  /// 3km 跨度时 routeScale=10000，半径=25m（直径50m），巨圆互相覆盖、
  /// 与地图上的小 pin 完全对不上。2026-10-05 用户要求上限 1m，
  /// 且圆内字、距离数字与圆同步缩放（字高 = 圆半径，保持 1:1）。
  static double _pinRadiusM(int scale) =>
      math.min(_mmOf(2.5, scale), 1.0);

  static double _roadHalfWidthM(RoadGrade g, int scale) =>
      _mmOf(_roadHalfWidthMm(g), scale);
  static double _roadLabelM(RoadGrade g, int scale) =>
      _mmOf(_roadLabelMm(g), scale);

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
