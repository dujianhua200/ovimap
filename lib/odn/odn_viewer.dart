import 'package:flutter/material.dart';

import '../export/topo.dart';
import '../models/map_label.dart';
import '../state/app_state.dart';
import 'core_check.dart';
import '../ui/dialogs.dart';

/// ODN 拓扑图交互页面。
///
/// 入口见 [openOdnTopoViewer]：先选工程（需含配线节点），再进图。
/// 图上复用 [Topology.buildTree] 建树，[CoreCheck] 做芯数占用校验：
/// 超用边标红，右上角「芯数校验」给出哪段超、超多少的清单；
/// 点击节点可查看详情并调用 [onLocateLabel] 定位回地图。

// ================= 入口 =================

/// 数据源选项（一份工程）。
class _OdnSrc {
  final String label;
  final Future<List<MapLabel>> Function() load;
  const _OdnSrc(this.label, this.load);
}

/// 打开 ODN 拓扑图：选工程 → 建树 → 推页面。
///
/// 未选/无配线节点时给友好提示，不进图。
/// [onLocateLabel] 由壳注入（节点点击定位需要地图相机控制权）。
Future<void> openOdnTopoViewer(
  BuildContext context,
  AppState st, {
  void Function(MapLabel label)? onLocateLabel,
}) async {
  final opts = <_OdnSrc>[];
  if (st.mode == AppMode.topoLink && st.topoColl.isNotEmpty) {
    final nm = await st.store.loadCollectionName(st.topoCid);
    opts.add(_OdnSrc(
      nm.isEmpty ? '当前配线收藏' : '当前配线收藏 · $nm',
      () async => st.topoColl,
    ));
  }
  if (st.labels.isNotEmpty) {
    opts.add(_OdnSrc(
      st.projectName.isEmpty ? '当前草稿' : '当前草稿 · ${st.projectName}',
      () async => st.labels,
    ));
  }
  for (final m in st.collections) {
    opts.add(_OdnSrc(
      m.name.isEmpty ? '未命名工程' : m.name,
      () => st.store.loadCollection(m.id),
    ));
  }
  if (!context.mounted) return;
  if (opts.isEmpty) {
    toast(context, '没有可查看的工程：请先在地图上标记光交箱/分光器箱/分纤盒/ONU 等配线节点');
    return;
  }

  _OdnSrc? picked;
  if (opts.length == 1) {
    picked = opts.single;
  } else {
    picked = await _pickOdnSrc(context, opts);
  }
  if (picked == null || !context.mounted) return;

  List<MapLabel> labels;
  try {
    labels = await picked.load();
  } catch (e) {
    if (context.mounted) toast(context, '读取工程失败：$e');
    return;
  }
  final src = picked;
  final topoCount = labels
      .where((l) => l.type.isTopoNode && l.type.role != 5 && l.type.role != 6)
      .length;
  if (topoCount == 0) {
    if (context.mounted) {
      toast(context, '「${src.label}」没有配线节点：'
          '请先在地图上标记光交箱/分光器箱/分纤盒/ONU 等');
    }
    return;
  }
  List<TopoNode> roots;
  try {
    roots = Topology.buildTree(labels);
  } on TopoException catch (e) {
    if (context.mounted) toast(context, '生成拓扑失败：$e');
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => OdnTopoPage(
      title: src.label,
      roots: roots,
      onLocateLabel: onLocateLabel,
    ),
  ));
}

Future<_OdnSrc?> _pickOdnSrc(BuildContext context, List<_OdnSrc> opts) async {
  _OdnSrc? picked;
  await showDarkDialog(
    context,
    title: '选择工程查看 ODN 拓扑图',
    content: SizedBox(
      width: double.maxFinite,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final o in opts)
            ListTile(
              dense: true,
              leading: const Icon(Icons.account_tree_outlined,
                  color: kAccent, size: 20),
              title: Text(o.label,
                  style:
                      const TextStyle(color: kTextMain, fontSize: 13.5)),
              onTap: () {
                picked = o;
                Navigator.pop(context);
              },
            ),
        ],
      ),
    ),
    actions: [darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub)],
  );
  return picked;
}

// ================= 页面 =================

class OdnTopoPage extends StatefulWidget {
  final String title;
  final List<TopoNode> roots;
  final void Function(MapLabel label)? onLocateLabel;

  const OdnTopoPage({
    super.key,
    required this.title,
    required this.roots,
    this.onLocateLabel,
  });

  @override
  State<OdnTopoPage> createState() => _OdnTopoPageState();
}

class _OdnTopoPageState extends State<OdnTopoPage> {
  static const double nodeW = 176;
  static const double nodeH = 76;
  static const double hGap = 44;
  static const double vGap = 118;
  static const double pad = 28;

  final _tc = TransformationController();

  late final CoreCheckResult _check;
  late final Map<TopoNode, CoreEdgeUse> _edgeOfChild;
  late final List<_Hit> _hits;
  late final Size _sceneSize;

  @override
  void initState() {
    super.initState();
    Topology.assignTitles(widget.roots);
    _check = CoreCheck.check(widget.roots);

    _edgeOfChild = {for (final e in _check.edges) e.child: e};
    _hits = [];
    var cursor = pad;
    var maxDepth = 0;
    for (final r in widget.roots) {
      cursor = _layout(r, cursor, 0);
    }
    for (final r in widget.roots) {
      final d = _maxDepth(r);
      if (d > maxDepth) maxDepth = d;
    }
    for (final n in Topology.flatten(widget.roots)) {
      _hits.add(_Hit(
        Rect.fromLTWH(n.x + pad, n.y + pad, nodeW, nodeH),
        n,
      ));
    }
    _sceneSize = Size(
      cursor - hGap + pad,
      pad + (maxDepth + 1) * (nodeH + vGap) - vGap + pad,
    );
  }

  double _layout(TopoNode n, double startX, int depth) {
    n.depth = depth;
    n.y = depth * (nodeH + vGap);
    if (n.children.isEmpty) {
      n.x = startX;
      return startX + nodeW + hGap;
    }
    var cur = startX;
    for (final c in n.children) {
      cur = _layout(c, cur, depth + 1);
    }
    n.x = (n.children.first.x + n.children.last.x) / 2;
    return cur;
  }

  int _maxDepth(TopoNode n) {
    var m = n.depth;
    for (final c in n.children) {
      final d = _maxDepth(c);
      if (d > m) m = d;
    }
    return m;
  }

  void _onTapUp(TapUpDetails d) {
    final scene = _tc.toScene(d.localPosition);
    for (final h in _hits) {
      if (h.rect.contains(scene)) {
        _showNodeSheet(h.node);
        return;
      }
    }
  }

  Future<void> _showNodeSheet(TopoNode n) {
    final e = _edgeOfChild[n];
    return showModalBottomSheet(
      context: context,
      backgroundColor: kPanelBg,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: n.src.type.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(n.title,
                      style:
                          const TextStyle(color: kTextMain, fontSize: 16)),
                ),
                Text(n.src.type.name,
                    style: const TextStyle(color: kTextSub, fontSize: 12)),
              ]),
              const SizedBox(height: 8),
              if (n.src.splitterRatio.trim().isNotEmpty)
                Text('分光比：${n.src.splitterRatio.trim()}',
                    style: const TextStyle(color: kTextSub, fontSize: 13)),
              if (e != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '上联光缆：${e.cable}（已用 ${e.used} 芯 / 共 ${e.total} 芯'
                    '${e.over ? '，超 ${e.overBy} 芯' : ''}）',
                    style: TextStyle(
                      color: e.over ? kDanger : kTextSub,
                      fontSize: 13,
                      fontWeight: e.over ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              Text('下级节点：${n.children.length} 个',
                  style: const TextStyle(color: kTextSub, fontSize: 13)),
              const SizedBox(height: 12),
              Row(children: [
                if (widget.onLocateLabel != null)
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.my_location, size: 18),
                      label: const Text('定位到地图'),
                      onPressed: () {
                        final cb = widget.onLocateLabel!;
                        final label = n.src;
                        Navigator.pop(ctx); // 先关底弹
                        Navigator.pop(context); // 再关拓扑页，露出地图
                        cb(label);
                      },
                    ),
                  ),
                if (widget.onLocateLabel != null) const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    child: const Text('关闭'),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCheckSheet() {
    final alerts = _check.alerts;
    return showModalBottomSheet(
      context: context,
      backgroundColor: kPanelBg,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (_, ctrl) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(
                    alerts.isEmpty ? Icons.check_circle : Icons.warning,
                    color: alerts.isEmpty ? Colors.green : kDanger,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      alerts.isEmpty
                          ? '芯数校验全部通过'
                          : '发现 ${alerts.length} 条告警',
                      style: TextStyle(
                        color: alerts.isEmpty ? kTextMain : kDanger,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text('共 ${_check.edges.length} 段有芯数光缆',
                      style:
                          const TextStyle(color: kTextSub, fontSize: 12)),
                ]),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView(
                    controller: ctrl,
                    children: [
                      if (alerts.isNotEmpty) ...[
                        for (final a in alerts)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('⚠ ${a.text}',
                                style: const TextStyle(
                                    color: kDanger, fontSize: 13)),
                          ),
                        const Divider(),
                      ],
                      for (final e in _check.edges)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${e.parent.title} → ${e.child.title}',
                                    style: const TextStyle(
                                        color: kTextMain, fontSize: 13),
                                  ),
                                  Text(e.cable,
                                      style: const TextStyle(
                                          color: kTextSub, fontSize: 12)),
                                ],
                              ),
                            ),
                            Text(
                              e.over
                                  ? '用${e.used}/共${e.total}（超${e.overBy}）'
                                  : '用${e.used}/共${e.total}',
                              style: TextStyle(
                                color: e.over ? kDanger : kTextSub,
                                fontSize: 12.5,
                                fontWeight: e.over
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ]),
                        ),
                      if (_check.edges.isEmpty)
                        const Text('没有填写芯数的光缆段：'
                            '在节点属性里填写「上级光缆芯数」后可参与校验。',
                            style:
                                TextStyle(color: kTextSub, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alertCount = _check.alerts.length;
    return Scaffold(
      backgroundColor: kPanelBg,
      appBar: AppBar(
        backgroundColor: kPanelBg,
        foregroundColor: kTextMain,
        title: Text('${widget.title} · ODN 拓扑图',
            style: const TextStyle(fontSize: 16)),
        actions: [
          TextButton.icon(
            icon: Icon(
              alertCount == 0 ? Icons.check_circle_outline : Icons.warning,
              color: alertCount == 0 ? Colors.green : kDanger,
              size: 18,
            ),
            label: Text(
              alertCount == 0 ? '芯数校验' : '芯数校验($alertCount)',
              style: TextStyle(
                  color: alertCount == 0 ? kTextSub : kDanger, fontSize: 13),
            ),
            onPressed: _showCheckSheet,
          ),
        ],
      ),
      body: Stack(children: [
        GestureDetector(
          onTapUp: _onTapUp,
          child: InteractiveViewer(
            transformationController: _tc,
            constrained: false,
            minScale: 0.15,
            maxScale: 4.0,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            child: CustomPaint(
              size: _sceneSize,
              painter: _TopoPainter(
                roots: widget.roots,
                edgeOfChild: _edgeOfChild,
                nodeW: nodeW,
                nodeH: nodeH,
                pad: pad,
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          bottom: 12,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: kPanelBg.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kTextSub.withValues(alpha: 0.3)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _LegendDot('正常光缆段', Color(0xFF78909C)),
                SizedBox(height: 4),
                _LegendDot('芯数超用', kDanger),
                SizedBox(height: 4),
                Text('双指/滚轮缩放 · 拖拽平移 · 点节点定位',
                    style: TextStyle(color: kTextSub, fontSize: 11)),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

class _Hit {
  final Rect rect;
  final TopoNode node;
  const _Hit(this.rect, this.node);
}

class _LegendDot extends StatelessWidget {
  final String text;
  final Color color;
  const _LegendDot(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 18, height: 3, color: color),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(color: kTextSub, fontSize: 11)),
    ]);
  }
}

/// 分层树绘制：节点方框（名称 + 分光比/端口数），边标注光缆规格；
/// 芯数超用的边标红。
class _TopoPainter extends CustomPainter {
  final List<TopoNode> roots;
  final Map<TopoNode, CoreEdgeUse> edgeOfChild;
  final double nodeW;
  final double nodeH;
  final double pad;

  _TopoPainter({
    required this.roots,
    required this.edgeOfChild,
    required this.nodeW,
    required this.nodeH,
    required this.pad,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in roots) {
      _drawNode(canvas, r);
    }
  }

  void _drawNode(Canvas canvas, TopoNode n) {
    final rect =
        RRect.fromRectAndRadius(Rect.fromLTWH(n.x + pad, n.y + pad, nodeW, nodeH),
            const Radius.circular(8));
    canvas.drawRRect(rect, Paint()..color = const Color(0xFF2A2A2E));
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = n.src.type.color,
    );

    final cx = n.x + pad + nodeW / 2;
    _text(canvas, n.title, Offset(cx, n.y + pad + 8),
        fontSize: 13.5, bold: true, center: true, color: kTextMain);
    if (n.sub.isNotEmpty) {
      _text(canvas, n.sub, Offset(cx, n.y + pad + 30),
          fontSize: 12, center: true, color: const Color(0xFFFF8A80));
    }
    final e = edgeOfChild[n];
    if (e != null) {
      _text(
        canvas,
        '用${e.used}/共${e.total}芯',
        Offset(cx, n.y + pad + 50),
        fontSize: 11,
        center: true,
        color: e.over ? kDanger : kTextSub,
        bold: e.over,
      );
    }

    for (final c in n.children) {
      _drawNode(canvas, c);
      final x1 = n.x + pad + nodeW / 2, y1 = n.y + pad + nodeH;
      final x2 = c.x + pad + nodeW / 2, y2 = c.y + pad;
      final ce = edgeOfChild[c];
      final over = ce != null && ce.over;
      final edgeColor = over ? kDanger : const Color(0xFF78909C);
      canvas.drawLine(
        Offset(x1, y1),
        Offset(x2, y2),
        Paint()
          ..color = edgeColor
          ..strokeWidth = over ? 3 : 2,
      );
      if (c.cable.isNotEmpty) {
        var label = c.cable;
        if (ce != null) label += ' · 用${ce.used}/共${ce.total}';
        final mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
        final tp = _tp(label, 11.5, over ? kDanger : const Color(0xFF90CAF9),
            bold: over);
        tp.layout();
        canvas.drawRect(
          Rect.fromCenter(
              center: Offset(mx, my),
              width: tp.width + 10,
              height: tp.height + 5),
          Paint()..color = kPanelBg,
        );
        tp.paint(canvas, Offset(mx - tp.width / 2, my - tp.height / 2));
      }
    }
  }

  TextPainter _tp(String text, double fontSize, Color color,
      {bool bold = false}) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
  }

  void _text(Canvas canvas, String text, Offset at,
      {required double fontSize,
      Color color = kTextMain,
      bool bold = false,
      bool center = false}) {
    final tp = _tp(text, fontSize, color, bold: bold);
    tp.layout(maxWidth: nodeW - 12);
    final dx = center ? at.dx - tp.width / 2 : at.dx;
    tp.paint(canvas, Offset(dx, at.dy));
  }

  @override
  bool shouldRepaint(covariant _TopoPainter old) => false;
}
