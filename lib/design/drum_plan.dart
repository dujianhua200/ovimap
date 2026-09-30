/// 光缆配盘表（纯 Dart，无 Flutter 依赖）。
///
/// 贪心 first-fit：按段落顺序装盘，每段需求 = 丈量长 + 接头预留（+引上预留）；
/// 同盘型号必须一致；超长段独占一盘并告警；余缆低于阈值告警。
library;

import '../geo/geo_util.dart';
import '../models/map_label.dart';

/// 未填写光缆型号时的展示值（入口处归一化，[planDrums] 内部同样兜底）。
const String unsetCableModel = '未填型号';

/// 是否"未填型号"（空串或已归一化的占位值）。
bool isUnsetCableModel(String model) {
  final m = model.trim();
  return m.isEmpty || m == unsetCableModel;
}

/// 敷设方式候选（仅标注用，不参与计算）。
const List<String> drumLayingMethods = ['架空', '管道', '直埋', '墙壁'];

/// 一段光缆：链上连续两点之间的一档。
class CableSeg {
  /// 段落文字，如 "XX杆→YY杆"。
  final String label;

  /// 丈量长（米）。
  final double lengthM;

  /// 光缆型号（如 "48芯GYTS"；空串 = 未填）。
  final String cableModel;

  /// 敷设方式（0=默认,1=架空,2=埋地,3=管道），仅标注用。
  final int segKind;

  /// 该段是否有引上（端点为引上点时为真）。
  final bool hasRiser;

  const CableSeg({
    required this.label,
    required this.lengthM,
    required this.cableModel,
    this.segKind = 0,
    this.hasRiser = false,
  });

  @override
  String toString() =>
      'CableSeg($label, ${lengthM.toStringAsFixed(1)}m, $cableModel)';
}

/// 配盘参数。
class DrumPlanParams {
  /// 单盘盘长（米），默认 2000。
  final double drumLengthM;

  /// 每处接头预留（米），默认 15。
  final double spliceSlackM;

  /// 每处引上预留（米），默认 15。
  final double riserSlackM;

  /// 是否计入引上预留（可选），默认计入。
  final bool countRiserSlack;

  /// 敷设方式（仅标注用）。
  final String layingMethod;

  /// 余缆过短告警阈值（米），默认 100。
  final double minRemnantM;

  const DrumPlanParams({
    this.drumLengthM = 2000,
    this.spliceSlackM = 15,
    this.riserSlackM = 15,
    this.countRiserSlack = true,
    this.layingMethod = '架空',
    this.minRemnantM = 100,
  });

  /// 单段需求长度 = 丈量长 + 接头预留（+引上预留）。
  double demandOf(CableSeg s) =>
      s.lengthM +
      spliceSlackM +
      (countRiserSlack && s.hasRiser ? riserSlackM : 0);
}

/// 一盘的配盘结果。
class DrumPlan {
  /// 盘号（1..N）。
  final int drumNo;

  /// 段落范围描述，如 "第1~3段（GK1→GK4）"。
  final String segs;

  /// 本盘光缆型号。
  final String cableModel;

  /// 已用长度（米，含全部预留）。
  final double usedM;

  /// 单盘盘长（米）。
  final double drumLengthM;

  /// 利用率 = usedM / drumLengthM。
  double get utilization => drumLengthM > 0 ? usedM / drumLengthM : 0;

  /// 告警（"超长告警…""余缆过短告警…"），无则空。
  final List<String> warnings;

  const DrumPlan({
    required this.drumNo,
    required this.segs,
    required this.cableModel,
    required this.usedM,
    required this.drumLengthM,
    this.warnings = const [],
  });

  @override
  String toString() => 'DrumPlan(#$drumNo, $cableModel, '
      '${usedM.toStringAsFixed(1)}/${drumLengthM.toStringAsFixed(0)}m)';
}

/// 内部装盘中的盘（可变）。
class _OpenDrum {
  /// 装盘键：trim 后的型号（空串 = 未填）。
  final String modelKey;
  final List<int> indices = [];
  final List<CableSeg> segs = [];
  double used = 0;
  final List<String> warnings = [];

  _OpenDrum(this.modelKey);
}

/// 贪心装盘：按段落顺序依次装入当前盘；型号不一致或装不下则关盘开新盘。
///
/// - 单段需求 > 单盘盘长：该段独占一盘并标记"超长告警"；
/// - 关盘时余缆 < [DrumPlanParams.minRemnantM]：标记"余缆过短告警"
///   （超长独占盘不计余缆，其"余缆"无意义）。
List<DrumPlan> planDrums(List<CableSeg> segs, DrumPlanParams params) {
  final drums = <DrumPlan>[];
  if (segs.isEmpty) return drums;

  var drumNo = 0;
  _OpenDrum? cur;

  void close(_OpenDrum d, {required bool oversize}) {
    drumNo++;
    if (!oversize) {
      final remnant = params.drumLengthM - d.used;
      if (remnant < params.minRemnantM) {
        d.warnings.add('余缆过短告警：余缆 ${remnant.toStringAsFixed(1)} 米，'
            '低于 ${params.minRemnantM.toStringAsFixed(0)} 米阈值');
      }
    }
    drums.add(DrumPlan(
      drumNo: drumNo,
      segs: _rangeDesc(d.indices, d.segs),
      cableModel: d.modelKey.isEmpty ? unsetCableModel : d.modelKey,
      usedM: d.used,
      drumLengthM: params.drumLengthM,
      warnings: List.unmodifiable(d.warnings),
    ));
  }

  void flush() {
    final c = cur;
    cur = null;
    if (c != null) close(c, oversize: false);
  }

  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    final demand = params.demandOf(s);
    final modelKey = s.cableModel.trim();
    // 超长段：先关当前盘，再独占一盘。
    if (demand > params.drumLengthM) {
      flush();
      final d = _OpenDrum(modelKey)
        ..indices.add(i)
        ..segs.add(s)
        ..used = demand
        ..warnings.add('超长告警：本段需求 ${demand.toStringAsFixed(1)} 米，'
            '超过单盘盘长 ${params.drumLengthM.toStringAsFixed(0)} 米');
      close(d, oversize: true);
      continue;
    }
    final c = cur;
    if (c != null &&
        c.modelKey == modelKey &&
        c.used + demand <= params.drumLengthM) {
      c.indices.add(i);
      c.segs.add(s);
      c.used += demand;
    } else {
      flush();
      cur = _OpenDrum(modelKey)
        ..indices.add(i)
        ..segs.add(s)
        ..used = demand;
    }
  }
  flush();
  return drums;
}

/// 段落范围描述：单段 → "第1段（A→B）"；多段 → "第1~3段（A→D）"。
String _rangeDesc(List<int> indices, List<CableSeg> segs) {
  String endName(String label) {
    final parts = label.split('→');
    return parts.length > 1 ? parts.last.trim() : label;
  }

  if (indices.length == 1) {
    return '第${indices.first + 1}段（${segs.first.label}）';
  }
  final from = segs.first.label.split('→').first.trim();
  final to = endName(segs.last.label);
  return '第${indices.first + 1}~${indices.last + 1}段（$from→$to）';
}

/// 从目标工程的 labels 取段落：按 [buildLabelChains] 拆链，链上连续两点为一段。
///
/// - lengthM 取"段长口径"：`distanceM ?? haversine`（人工确认值优先）；
/// - label 取 "起点名→终点名"（名空时回退备注/序号）；
/// - cableModel 取该段终点 [MapLabel.segCable]，空则归一化为 [unsetCableModel]；
/// - hasRiser：同一线组内存在序号落在两端点序号区间内的引上点
///   （typeId == 'riser'）即视为该段有引上。引上点是独立个体，不参与成链，
///   故用"同组序号区间"判定而非端点类型。
List<CableSeg> buildCableSegsFromLabels(List<MapLabel> labels) {
  // 同线组引上点的序号集合（按组预建，段内二分无需）。
  final riserSeqs = <String, List<int>>{};
  for (final l in labels) {
    if (l.typeId != 'riser' || l.lineGroupId.isEmpty) continue;
    (riserSeqs[l.lineGroupId] ??= <int>[]).add(l.seq);
  }

  final segs = <CableSeg>[];
  for (final chain in buildLabelChains(labels)) {
    final risers = riserSeqs[chain.first.lineGroupId] ?? const <int>[];
    for (var i = 1; i < chain.length; i++) {
      final a = chain[i - 1], b = chain[i];
      final dm = b.distanceM;
      final lengthM = (dm != null && dm > 0)
          ? dm
          : GeoUtil.haversine(a.lat, a.lon, b.lat, b.lon);
      final model = b.segCable.trim();
      final lo = a.seq < b.seq ? a.seq : b.seq;
      final hi = a.seq < b.seq ? b.seq : a.seq;
      segs.add(CableSeg(
        label: '${_pointName(a)}→${_pointName(b)}',
        lengthM: lengthM,
        cableModel: model.isEmpty ? unsetCableModel : model,
        segKind: b.segKind,
        hasRiser: risers.any((s) => s >= lo && s <= hi),
      ));
    }
  }
  return segs;
}

String _pointName(MapLabel l) {
  final n = l.name.trim();
  if (n.isNotEmpty) return n;
  final note = l.note.trim();
  if (note.isNotEmpty) return note;
  return '点${l.seq}';
}
