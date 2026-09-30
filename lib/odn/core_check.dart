import '../export/topo.dart';

/// ODN 光缆芯数占用校验（纯逻辑，不依赖 UI，可单测）。
///
/// ## 校验规则（PON 口径）
///
/// 对拓扑树上每条「有芯数」的边（子节点的 `cableCores > 0`，即上级光缆总芯数已知）：
/// - `total` = 该段光缆总芯数；
/// - `used` = 该段下行实际占用的芯数，对子节点整棵子树递归折算：
///   1. **叶子节点**（无下级，如 ONU 直熔）→ 占 **1 芯**；
///   2. **带分光器的节点**（`splitterRatio` 能解析出 `1:K`，K>0）→ 占 **1 芯**：
///      PON 原理，一台分光器的全部下行端口由其上联的 1 芯承载，
///      无论下面挂了多少终端都不再向下展开（「经分光器时按其分光比折算」
///      即：K 个下行端口折算为上游 1 芯）；
///   3. **无分光器的中间节点**（如直熔交接箱，只是透传）→ 占其各下级占用之和
///      （每个下级各占各的上游芯数）。
/// - `used > total` 时记为**芯数超用**告警（`overBy = used - total`）。
///
/// 另附**端口数校验**（与「芯线占用表 CSV」同口径）：分光比为 `1:K` 的节点，
/// 下级节点数 > K 时记为端口超用告警。
///
/// 典型例子：一段 12 芯光缆喂给一台 1:8 分光器箱，
/// 分光器下挂 8 个分纤盒 → used = 1（分光器占 1 芯），不超用；
/// 若交接箱下直熔挂 13 个 ONU（无分光器）→ used = 13 > 12，超用 1 芯。
class CoreEdgeUse {
  /// 上级节点（光缆的本端）。
  final TopoNode parent;

  /// 下级节点（光缆规格/芯数记在该节点身上）。
  final TopoNode child;

  /// 光缆规格（边标注，如 "48芯GYTS"）。
  final String cable;

  /// 光缆总芯数。
  final int total;

  /// 已用芯数（按上述规则折算）。
  final int used;

  const CoreEdgeUse({
    required this.parent,
    required this.child,
    required this.cable,
    required this.total,
    required this.used,
  });

  /// 是否超用。
  bool get over => used > total;

  /// 超出多少芯（未超用时为 0）。
  int get overBy => over ? used - total : 0;
}

/// 一条校验告警。
class CoreCheckAlert {
  /// 是否为芯数超用（false = 端口数超用）。
  final bool isCoreOver;

  /// 涉及的边（端口超用时为 null）。
  final CoreEdgeUse? edge;

  /// 涉及的节点（端口超用时为该分光器节点）。
  final TopoNode? node;

  final String text;

  const CoreCheckAlert({
    required this.isCoreOver,
    required this.text,
    this.edge,
    this.node,
  });
}

/// 校验结果：每条有芯数边的占用 + 告警清单。
class CoreCheckResult {
  /// 所有有芯数（`cableCores > 0`）的边，先序排列。
  final List<CoreEdgeUse> edges;

  /// 告警清单（芯数超用在前，端口超用在后）。
  final List<CoreCheckAlert> alerts;

  const CoreCheckResult({required this.edges, required this.alerts});

  bool get ok => alerts.isEmpty;

  /// 芯数超用的边（`used > total`）。
  List<CoreEdgeUse> get overEdges => edges.where((e) => e.over).toList();
}

class CoreCheck {
  CoreCheck._();

  /// 对拓扑树做芯数占用 + 端口数校验。
  static CoreCheckResult check(List<TopoNode> roots) {
    final edges = <CoreEdgeUse>[];
    final alerts = <CoreCheckAlert>[];
    for (final n in Topology.flatten(roots)) {
      // 端口数校验：分光比 1:K 的节点，下级数不应超过 K。
      final ratio = Topology.parseRatio(n.src.splitterRatio);
      if (ratio > 0 && n.children.length > ratio) {
        alerts.add(CoreCheckAlert(
          isCoreOver: false,
          node: n,
          text: '端口超用：${n.title} 分光比 1:$ratio，'
              '已接 ${n.children.length} 个下级（超 ${n.children.length - ratio} 个）',
        ));
      }
      // 芯数校验：只看 cableCores > 0 的边。
      for (final c in n.children) {
        final total = c.cableCores;
        if (total <= 0) continue;
        final used = demandOf(c);
        final e = CoreEdgeUse(
          parent: n,
          child: c,
          cable: c.cable.isEmpty ? '未标注规格' : c.cable,
          total: total,
          used: used,
        );
        edges.add(e);
        if (e.over) {
          alerts.add(CoreCheckAlert(
            isCoreOver: true,
            edge: e,
            text: '芯数超用：${n.title} → ${c.title}（${e.cable}）'
                '已用 ${e.used} 芯 / 共 ${e.total} 芯，超 ${e.overBy} 芯',
          ));
        }
      }
    }
    // 芯数告警排前面，端口告警排后面。
    alerts.sort((a, b) =>
        (a.isCoreOver ? 0 : 1).compareTo(b.isCoreOver ? 0 : 1));
    return CoreCheckResult(edges: edges, alerts: alerts);
  }

  /// 子树根节点对其上联光缆的芯数占用（递归折算，见文件头规则）。
  ///
  /// - 带分光器（能解析出 1:K）→ 1；
  /// - 叶子 → 1；
  /// - 无分光器的中间节点 → 各下级占用之和。
  static int demandOf(TopoNode n) {
    if (Topology.parseRatio(n.src.splitterRatio) > 0) return 1;
    if (n.children.isEmpty) return 1;
    var sum = 0;
    for (final c in n.children) {
      sum += demandOf(c);
    }
    return sum;
  }
}
