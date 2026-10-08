/// 拓扑图编辑器（Phase 2）：人工构建设备间光缆拓扑连线。
///
/// 设计原则（docs/telecom_redesign.md）：
/// - 无自动拓扑、无自动挂接、无层级推断，全部由人工点选；
/// - 路由图汇总独立设备 → 本页只做逻辑连线；
/// - 三端共用 Flutter 原生组件，无平台特定代码。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/models/reno_state.dart';
import 'package:ovimap/models/topo_check.dart';
import 'package:ovimap/ui/design_tokens.dart';

/// 可参与拓扑连线的设备：排除纯文字等不可连线类型。
List<MapLabel> topoLinkableDevices(List<MapLabel> labels) =>
    [for (final l in labels) if (l.type.isTopoLinkable) l];

/// 拓扑画布节点布局（纯函数，可单测）。
///
/// 经纬度归一化到画布（Y 翻转），保持纵横比、居中；
/// 全部点位重合（或跨度为 0）时退化为均匀网格。
Map<String, Offset> layoutTopoNodes(List<MapLabel> devices, Size size) {
  const pad = 56.0;
  final result = <String, Offset>{};
  if (devices.isEmpty || size.isEmpty) return result;

  final w = math.max(size.width - pad * 2, 1.0);
  final h = math.max(size.height - pad * 2, 1.0);

  var minLon = devices.first.lon,
      maxLon = devices.first.lon,
      minLat = devices.first.lat,
      maxLat = devices.first.lat;
  for (final d in devices.skip(1)) {
    if (d.lon < minLon) minLon = d.lon;
    if (d.lon > maxLon) maxLon = d.lon;
    if (d.lat < minLat) minLat = d.lat;
    if (d.lat > maxLat) maxLat = d.lat;
  }
  final lonSpan = maxLon - minLon;
  final latSpan = maxLat - minLat;

  if (lonSpan < 1e-9 && latSpan < 1e-9) {
    // 网格退化布局
    final n = devices.length;
    final cols = math.max(math.sqrt(n).ceil(), 1);
    final rows = math.max((n / cols).ceil(), 1);
    for (var i = 0; i < n; i++) {
      final col = i % cols;
      final row = i ~/ cols;
      result[devices[i].id] = Offset(
        pad + (cols == 1 ? w / 2 : w * col / (cols - 1)),
        pad + (rows == 1 ? h / 2 : h * row / (rows - 1)),
      );
    }
    return result;
  }

  final scale = math.min(w / math.max(lonSpan, 1e-9), h / math.max(latSpan, 1e-9));
  final ox = pad + (w - lonSpan * scale) / 2;
  final oy = pad + (h - latSpan * scale) / 2;
  for (final d in devices) {
    result[d.id] = Offset(
      ox + (d.lon - minLon) * scale,
      oy + (maxLat - d.lat) * scale,
    );
  }
  return result;
}

/// 点到线段距离（连线点选删除用）。
double pointToSegment(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx, dy = b.dy - a.dy;
  final len2 = dx * dx + dy * dy;
  if (len2 < 1e-9) return (p - a).distance;
  var t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  return (p - Offset(a.dx + dx * t, a.dy + dy * t)).distance;
}

/// 拓扑图编辑器页面。
///
/// [devices] 当前工程的独立设备（MapLabel）；[initialLinks] 已有连线。
/// 连线变更通过 [onChanged] 回传，父级负责落盘。
class TopoEditorPage extends StatefulWidget {
  final List<MapLabel> devices;
  final List<FiberLink> initialLinks;
  final void Function(List<FiberLink> links)? onChanged;

  /// 路由图杆路段（用于改造三态标记）；为空时不显示"杆路段"页签。
  final List<MapLabel> routeLabels;
  final void Function()? onRouteChanged;

  const TopoEditorPage({
    super.key,
    required this.devices,
    this.initialLinks = const [],
    this.onChanged,
    this.routeLabels = const [],
    this.onRouteChanged,
  });

  @override
  State<TopoEditorPage> createState() => _TopoEditorPageState();
}

class _TopoEditorPageState extends State<TopoEditorPage> {
  late List<MapLabel> _devices;
  late List<FiberLink> _links;
  Map<String, Offset> _pos = {};

  String? _fromId;
  String? _toId;
  bool _linkMode = true; // 连线模式开关（默认开：点选即连线）

  @override
  void initState() {
    super.initState();
    _devices = topoLinkableDevices(widget.devices);
    _links = [for (final l in widget.initialLinks) l.clone()];
  }

  void _emit() => widget.onChanged?.call([for (final l in _links) l.clone()]);

  MapLabel? _byId(String? id) {
    if (id == null) return null;
    for (final d in _devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  String _labelOf(MapLabel d) => d.name.isNotEmpty ? d.name : d.type.name;

  void _onTapDown(TapDownDetails details, Size canvasSize) {
    if (!_linkMode) return;
    final p = details.localPosition;
    // 1) 先看是否点中连线（删除）
    for (final l in _links) {
      final a = _pos[l.fromDeviceId], b = _pos[l.toDeviceId];
      if (a == null || b == null) continue;
      if (pointToSegment(p, a, b) < 14) {
        _confirmDeleteLink(l);
        return;
      }
    }
    // 2) 点中设备节点
    String? hit;
    var best = 34.0;
    _pos.forEach((id, o) {
      final d = (p - o).distance;
      if (d < best) {
        best = d;
        hit = id;
      }
    });
    if (hit == null) {
      setState(() {
        _fromId = null;
        _toId = null;
      });
      return;
    }
    setState(() {
      if (_fromId == null) {
        _fromId = hit;
      } else if (_fromId == hit) {
        _fromId = null; // 再点一次取消
      } else {
        _toId = hit;
      }
    });
    if (_fromId != null && _toId != null) {
      _openLinkForm(_byId(_fromId)!, _byId(_toId)!);
    }
  }

  Future<void> _openLinkForm(MapLabel from, MapLabel to) async {
    final link = await showDialog<FiberLink>(
      context: context,
      builder: (_) => FiberLinkFormDialog(from: from, to: to),
    );
    if (!mounted) return;
    if (link != null) {
      setState(() {
        _links.add(link);
        _fromId = null;
        _toId = null;
      });
      _emit();
      if (_linkMode && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已保存 ${_labelOf(from)} → ${_labelOf(to)}，继续点选下一对设备'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else {
      // 取消：保留起点选择，方便换终点
      setState(() => _toId = null);
    }
  }

  Future<void> _confirmDeleteLink(FiberLink l) async {
    final from = _byId(l.fromDeviceId);
    final to = _byId(l.toDeviceId);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除连线'),
        content: Text(
          '${from != null ? _labelOf(from) : '?'} → ${to != null ? _labelOf(to) : '?'}\n'
          '${l.fullSpec.isEmpty ? '（未填参数）' : l.fullSpec}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: TokC.danger)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => _links.removeWhere((e) => e.id == l.id));
      _emit();
    }
  }

  Future<void> _runValidate() async {
    final issues = validateTopology(_devices, _links);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('拓扑校验${issues.isEmpty ? '通过' : '发现 ${issues.length} 个问题'}'),
        content: SizedBox(
          width: 320,
          child: issues.isEmpty
              ? const Row(
                  children: [
                    Icon(Icons.check_circle, color: TokC.ok),
                    SizedBox(width: TokSp.s),
                    Text('未发现问题'),
                  ],
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: issues.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final it = issues[i];
                    return ListTile(
                      dense: true,
                      leading: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: TokSp.xs, vertical: 2),
                        decoration: BoxDecoration(
                          color: TokC.warn.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(TokR.s),
                        ),
                        child: Text(it.kind,
                            style: const TextStyle(fontSize: TokFs.micro)),
                      ),
                      title: Text(it.message,
                          style: const TextStyle(fontSize: TokFs.small)),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String get _hint {
    if (!_linkMode) return '查看模式：打开右上角"连线"开关后可点选连线';
    if (_fromId == null) return '点选起点设备';
    final from = _byId(_fromId);
    if (_toId == null) {
      return '已选起点：${from != null ? _labelOf(from) : ''}，请点选终点设备';
    }
    return '正在填写连线参数…';
  }

  @override
  Widget build(BuildContext context) {
    final showSegTab = widget.routeLabels.isNotEmpty;
    return DefaultTabController(
      length: showSegTab ? 2 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('拓扑图'),
          actions: [
            IconButton(
              tooltip: '一键校验',
              icon: const Icon(Icons.fact_check_outlined),
              onPressed: _runValidate,
            ),
            Row(
              children: [
                const Text('连线', style: TextStyle(fontSize: TokFs.small)),
                Switch(
                  value: _linkMode,
                  onChanged: (v) => setState(() {
                    _linkMode = v;
                    _fromId = null;
                    _toId = null;
                  }),
                ),
              ],
            ),
          ],
          bottom: showSegTab
              ? const TabBar(
                  tabs: [
                    Tab(text: '光缆连线'),
                    Tab(text: '杆路段'),
                  ],
                )
              : null,
        ),
        body: showSegTab
            ? TabBarView(
                children: [
                  _buildLinkTab(),
                  _buildSegmentTab(),
                ],
              )
            : _buildLinkTab(),
      ),
    );
  }

  /// 光缆连线页签（原有画布 + 提示条）。
  Widget _buildLinkTab() {
    return Column(
      children: [
        Expanded(
          child: _devices.isEmpty
              ? const Center(child: Text('暂无可连线设备，请先在路由图添加设备'))
              : LayoutBuilder(
                  builder: (ctx, constraints) {
                    final size =
                        Size(constraints.maxWidth, constraints.maxHeight);
                    _pos = layoutTopoNodes(_devices, size);
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => _onTapDown(d, size),
                      child: CustomPaint(
                        key: const ValueKey('topo_canvas'),
                        size: size,
                        painter: _TopoPainter(
                          devices: _devices,
                          links: _links,
                          pos: _pos,
                          fromId: _fromId,
                          toId: _toId,
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
              horizontal: TokSp.l, vertical: TokSp.s),
          decoration: const BoxDecoration(
            color: TokC.toolbar,
            border: Border(top: BorderSide(color: TokC.divider)),
          ),
          child: Text(
            _hint,
            style: const TextStyle(fontSize: TokFs.small, color: TokC.textSubConst),
          ),
        ),
      ],
    );
  }

  /// 杆路段页签：逐段标记改造三态（原有/新增/拆除）。
  /// 三态记在"本段终点"（chain[i].reno），即上一杆→本杆。
  Widget _buildSegmentTab() {
    final chains = buildLabelChains(widget.routeLabels);
    final segs = <MapLabel>[];
    for (final chain in chains) {
      for (var i = 1; i < chain.length; i++) {
        segs.add(chain[i]); // 用终点代表该段
      }
    }
    if (segs.isEmpty) {
      return const Center(child: Text('暂无杆路段，请先在路由图打点连杆'));
    }
    String segName(MapLabel to) {
      // 找到该段起点名称
      String from = '';
      for (final chain in chains) {
        for (var i = 1; i < chain.length; i++) {
          if (chain[i].id == to.id) {
            from = _labelOf(chain[i - 1]);
            break;
          }
        }
      }
      return '$from → ${_labelOf(to)}';
    }

    return ListView.separated(
      itemCount: segs.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final to = segs[i];
        return ListTile(
          dense: true,
          title: Text(segName(to), style: const TextStyle(fontSize: TokFs.small)),
          trailing: DropdownButton<int>(
            value: to.reno,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(
                  value: RenoState.existing, child: Text('原有')),
              DropdownMenuItem(value: RenoState.added, child: Text('新增')),
              DropdownMenuItem(
                  value: RenoState.removed, child: Text('拆除')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => to.reno = v);
              widget.onRouteChanged?.call();
            },
          ),
        );
      },
    );
  }
}

/// 拓扑画布绘制：连线（直线+芯数标注）+ 设备节点（编号在上）。
class _TopoPainter extends CustomPainter {
  final List<MapLabel> devices;
  final List<FiberLink> links;
  final Map<String, Offset> pos;
  final String? fromId;
  final String? toId;

  _TopoPainter({
    required this.devices,
    required this.links,
    required this.pos,
    this.fromId,
    this.toId,
  });

  static const double nodeR = 22;

  @override
  void paint(Canvas canvas, Size size) {
    final linkPaint = Paint()
      ..color = TokC.accent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    // 连线
    for (final l in links) {
      final a = pos[l.fromDeviceId], b = pos[l.toDeviceId];
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, linkPaint);
      // 芯数标注（中点小 pill）
      final label = l.cores > 0 ? '${l.cores}芯' : '—';
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      _drawPill(canvas, mid, label);
    }

    // 节点
    for (final d in devices) {
      final o = pos[d.id];
      if (o == null) continue;
      final selected = d.id == fromId || d.id == toId;
      if (selected) {
        canvas.drawCircle(
          o,
          nodeR + 6,
          Paint()
            ..color = TokC.accent.withOpacity(0.25)
            ..style = PaintingStyle.fill,
        );
      }
      canvas.drawCircle(o, nodeR, Paint()..color = d.type.color);
      canvas.drawCircle(
        o,
        nodeR,
        Paint()
          ..color = const Color(0xFF000000)
          ..strokeWidth = selected ? 3 : 1.5
          ..style = PaintingStyle.stroke,
      );
      // 类型符号字
      final sym = d.type.symbol.isEmpty ? '?' : d.type.symbol;
      _drawText(canvas, o, sym, TokFs.body, const Color(0xFFFFFFFF), bold: true);
      // 编号在上
      final name = d.name.isNotEmpty ? d.name : d.type.name;
      _drawText(canvas, o + const Offset(0, -nodeR - 14), name, TokFs.small,
          TokC.textMain,
          bold: selected);
    }
  }

  void _drawText(
      Canvas canvas, Offset o, String text, double fs, Color color,
      {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fs,
          color: color,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    tp.paint(canvas, o - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawPill(Canvas canvas, Offset mid, String text) {
    final tp = TextPainter(
      text: const TextSpan(
        text: '',
        style: TextStyle(fontSize: TokFs.micro, color: TokC.textMainConst),
      ),
      textDirection: TextDirection.ltr,
    );
    final span = TextSpan(
      text: text,
      style: const TextStyle(fontSize: TokFs.micro, color: TokC.textMainConst),
    );
    tp.text = span;
    tp.layout();
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: mid, width: tp.width + 12, height: tp.height + 6),
      const Radius.circular(8),
    );
    canvas.drawRRect(
        rect, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawRRect(
        rect,
        Paint()
          ..color = TokC.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
    tp.paint(canvas, mid - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _TopoPainter old) =>
      old.devices != devices ||
      old.links != links ||
      old.pos != pos ||
      old.fromId != fromId ||
      old.toId != toId;
}

/// 光缆连线参数表单对话框。
///
/// 芯数：6/12/24/48/96/144 下拉 + 自定义输入；
/// 敷设方式：架空/管道/直埋/引上；另有型号、长度、厂家、熔接方式。
class FiberLinkFormDialog extends StatefulWidget {
  final MapLabel from;
  final MapLabel to;

  const FiberLinkFormDialog({super.key, required this.from, required this.to});

  @override
  State<FiberLinkFormDialog> createState() => _FiberLinkFormDialogState();
}

class _FiberLinkFormDialogState extends State<FiberLinkFormDialog> {
  int? _cores = 48;
  bool _customCores = false;
  final _customCoresCtrl = TextEditingController();
  final _modelCtrl = TextEditingController(text: 'GYTS');
  int _layMethod = 1;
  final _lenCtrl = TextEditingController();
  final _mfrCtrl = TextEditingController();
  String _splice = '熔接';
  int _reno = RenoState.existing;

  @override
  void dispose() {
    _customCoresCtrl.dispose();
    _modelCtrl.dispose();
    _lenCtrl.dispose();
    _mfrCtrl.dispose();
    super.dispose();
  }

  String _nameOf(MapLabel d) => d.name.isNotEmpty ? d.name : d.type.name;

  void _save() {
    int cores = 0;
    if (_customCores) {
      cores = int.tryParse(_customCoresCtrl.text.trim()) ?? 0;
    } else {
      cores = _cores ?? 0;
    }
    final len = double.tryParse(_lenCtrl.text.trim()) ?? 0;
    Navigator.pop(
      context,
      FiberLink(
        fromDeviceId: widget.from.id,
        toDeviceId: widget.to.id,
        cores: cores,
        cableModel: _modelCtrl.text.trim(),
        manufacturer: _mfrCtrl.text.trim(),
        layMethod: _layMethod,
        lengthM: len < 0 ? 0 : len,
        spliceMethod: _splice,
        reno: _reno,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${_nameOf(widget.from)} → ${_nameOf(widget.to)}'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 芯数
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      value: _customCores ? null : _cores,
                      decoration: const InputDecoration(
                          labelText: '芯数', isDense: true),
                      items: [
                        for (final c in kCommonFiberCores)
                          DropdownMenuItem(value: c, child: Text('$c 芯')),
                      ],
                      onChanged: (v) => setState(() {
                        _customCores = false;
                        _cores = v;
                      }),
                    ),
                  ),
                  const SizedBox(width: TokSp.s),
                  TextButton(
                    onPressed: () =>
                        setState(() => _customCores = !_customCores),
                    child: Text(_customCores ? '选常用' : '自定义'),
                  ),
                ],
              ),
              if (_customCores)
                TextField(
                  controller: _customCoresCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '自定义芯数',
                    hintText: '如 288',
                    isDense: true,
                  ),
                ),
              const SizedBox(height: TokSp.s),
              TextField(
                controller: _modelCtrl,
                decoration: const InputDecoration(
                  labelText: '光缆型号',
                  hintText: '如 GYTS',
                  isDense: true,
                ),
              ),
              const SizedBox(height: TokSp.s),
              DropdownButtonFormField<int>(
                value: _layMethod,
                decoration:
                    const InputDecoration(labelText: '敷设方式', isDense: true),
                items: [
                  for (final e in kLayMethods.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _layMethod = v ?? 1),
              ),
              const SizedBox(height: TokSp.s),
              DropdownButtonFormField<int>(
                value: _reno,
                decoration:
                    const InputDecoration(labelText: '改造状态', isDense: true),
                items: const [
                  DropdownMenuItem(
                      value: RenoState.existing, child: Text('原有')),
                  DropdownMenuItem(value: RenoState.added, child: Text('新增')),
                  DropdownMenuItem(
                      value: RenoState.removed, child: Text('拆除')),
                ],
                onChanged: (v) =>
                    setState(() => _reno = v ?? RenoState.existing),
              ),
              const SizedBox(height: TokSp.s),
              TextField(
                controller: _lenCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '长度（米）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: TokSp.s),
              TextField(
                controller: _mfrCtrl,
                decoration: const InputDecoration(
                  labelText: '厂家',
                  isDense: true,
                ),
              ),
              const SizedBox(height: TokSp.s),
              DropdownButtonFormField<String>(
                value: _splice,
                decoration:
                    const InputDecoration(labelText: '熔接方式', isDense: true),
                items: const [
                  DropdownMenuItem(value: '熔接', child: Text('熔接')),
                  DropdownMenuItem(value: '冷接', child: Text('冷接')),
                ],
                onChanged: (v) => setState(() => _splice = v ?? '熔接'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存连线'),
        ),
      ],
    );
  }
}
