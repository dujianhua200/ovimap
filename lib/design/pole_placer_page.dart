import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/fav_node.dart';
import '../models/label_type.dart';
import '../models/map_label.dart';
import '../state/app_state.dart';
import '../state/fav_tree_controller.dart';
import '../ui/design_tokens.dart';
import '../ui/dialogs.dart';
import 'pole_placer.dart';

/// 打开"智能布杆"对话框：参数表单 + 杆位预览 + 确认写入目标工程。
///
/// 从工程的线组（chain）取线路点列；布杆结果作为
/// `MapLabel(typeId: 杆型, name: 杆号)` 批量加入该工程，经
/// [AppState.undoStack] 可撤销（undo 按 id 删除这批杆）。
Future<void> showPolePlacerDialog(
  BuildContext context, {
  required AppState st,
  required FavTreeController controller,
  required FavNode projectNode,
}) async {
  if (!projectNode.isProject) return;
  final labels = await controller.labelsOf(projectNode.id);
  if (!context.mounted) return;
  final chains = buildLabelChains(labels);
  if (chains.isEmpty) {
    toast(context, '「${projectNode.name}」内没有线路（线组为空），无法布杆');
    return;
  }
  final existingNames = <String>{
    for (final l in labels)
      if (l.name.isNotEmpty) l.name,
  };
  var baseSeq = 0;
  for (final l in labels) {
    if (l.seq > baseSeq) baseSeq = l.seq;
  }
  await showDarkDialog(
    context,
    title: '智能布杆 · ${projectNode.name}',
    width: 460,
    content: _PolePlacerForm(
      st: st,
      cid: projectNode.id,
      projectName: projectNode.name,
      chains: chains,
      existingNames: existingNames,
      baseSeq: baseSeq,
    ),
  );
}

class _PolePlacerForm extends StatefulWidget {
  final AppState st;
  final String cid;
  final String projectName;
  final List<List<MapLabel>> chains;
  final Set<String> existingNames;
  final int baseSeq;

  const _PolePlacerForm({
    required this.st,
    required this.cid,
    required this.projectName,
    required this.chains,
    required this.existingNames,
    required this.baseSeq,
  });

  @override
  State<_PolePlacerForm> createState() => _PolePlacerFormState();
}

class _PolePlacerFormState extends State<_PolePlacerForm> {
  static const _poleTypes = ['concrete', 'wood', 'electric'];

  int _chainIdx = 0;
  final _spanCtrl = TextEditingController(text: '50');
  final _prefixCtrl = TextEditingController(text: 'G');
  final _startCtrl = TextEditingController(text: '1');
  final _digitsCtrl = TextEditingController(text: '3');
  String _poleTypeId = 'concrete';
  bool _cornerMustHave = true;

  double _spanM = 50;
  String _prefix = 'G';
  int _startNo = 1;
  int _digits = 3;

  List<PolePlan> _plans = const [];
  double _routeLen = 0;
  double _maxSpan = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 默认选最长的线组。
    var best = 0;
    for (var i = 1; i < widget.chains.length; i++) {
      if (widget.chains[i].length > widget.chains[best].length) best = i;
    }
    _chainIdx = best;
    _recalc();
  }

  @override
  void dispose() {
    _spanCtrl.dispose();
    _prefixCtrl.dispose();
    _startCtrl.dispose();
    _digitsCtrl.dispose();
    super.dispose();
  }

  void _recalc() {
    final route = [
      for (final l in widget.chains[_chainIdx]) RoutePoint(l.lat, l.lon),
    ];
    _routeLen = PolePlacer.routeLengthM(route);
    _plans = PolePlacer.place(
      route: route,
      spanM: _spanM,
      prefix: _prefix,
      startNo: _startNo,
      digits: _digits,
      cornerMustHave: _cornerMustHave,
      takenNames: widget.existingNames,
    );
    _maxSpan = PolePlacer.maxSpanM(_plans);
  }

  String _typeName(String id) => LabelType.fromId(id).name;

  Future<void> _confirm() async {
    if (_plans.isEmpty || _busy) return;
    setState(() => _busy = true);
    final newLabels = [
      for (var i = 0; i < _plans.length; i++)
        MapLabel(
          typeId: _poleTypeId,
          seq: widget.baseSeq + i + 1,
          lat: _plans[i].lat,
          lon: _plans[i].lon,
          name: _plans[i].name,
        ),
    ];
    final st = widget.st;
    final cid = widget.cid;
    final ok = await st.undoStack.execute(
      '智能布杆（${newLabels.length} 根）',
      () async {
        final cur = st.overlayLabels[cid] ?? await st.store.loadCollection(cid);
        final have = cur.map((e) => e.id).toSet();
        final fresh = newLabels.where((e) => !have.contains(e.id)).toList();
        if (fresh.isEmpty) return false;
        cur.addAll(fresh);
        await st.store.saveCollectionLabels(cid, cur);
        await st.store.setCollectionCount(cid, cur.length);
        await st.refreshCollections();
        return true;
      },
      () async {
        final ids = newLabels.map((e) => e.id).toSet();
        final cur = st.overlayLabels[cid] ?? await st.store.loadCollection(cid);
        cur.removeWhere((e) => ids.contains(e.id));
        await st.store.saveCollectionLabels(cid, cur);
        await st.store.setCollectionCount(cid, cur.length);
        await st.refreshCollections();
        return true;
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.pop(context);
      toast(context, '已布杆 ${newLabels.length} 根（${_plans.first.name}'
          '～${_plans.last.name}），可撤销');
    } else {
      toast(context, '布杆失败：工程数据已失效');
    }
  }

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(color: kTextSub, fontSize: TokFs.body);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.chains.length > 1)
            DropdownButtonFormField<int>(
              initialValue: _chainIdx,
              dropdownColor: TokC.panelSolid,
              isExpanded: true,
              style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
              decoration: dec('布杆线路'),
              items: [
                for (var i = 0; i < widget.chains.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text('线路${i + 1}（${widget.chains[i].length} 点）'),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _chainIdx = v;
                  _recalc();
                });
              },
            ),
          if (widget.chains.length > 1) const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _spanCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
                  ],
                  style: const TextStyle(color: kTextMain),
                  decoration: dec('档距（米）'),
                  onChanged: (v) {
                    final d = double.tryParse(v);
                    if (d != null && d > 0) {
                      setState(() {
                        _spanM = d;
                        _recalc();
                      });
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _prefixCtrl,
                  style: const TextStyle(color: kTextMain),
                  decoration: dec('杆号前缀'),
                  onChanged: (v) => setState(() {
                    _prefix = v;
                    _recalc();
                  }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(color: kTextMain),
                  decoration: dec('起始号'),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 0) {
                      setState(() {
                        _startNo = n;
                        _recalc();
                      });
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _digitsCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(color: kTextMain),
                  decoration: dec('编号位数'),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 1 && n <= 6) {
                      setState(() {
                        _digits = n;
                        _recalc();
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _poleTypeId,
            dropdownColor: TokC.panelSolid,
            isExpanded: true,
            style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
            decoration: dec('杆型'),
            items: [
              for (final id in _poleTypes)
                DropdownMenuItem(value: id, child: Text(_typeName(id))),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _poleTypeId = v);
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('拐点必立杆', style: labelStyle),
            subtitle: const Text('转角超过 30° 的顶点强制立杆，档距从拐点重算',
                style: TextStyle(color: kTextHint, fontSize: 12)),
            value: _cornerMustHave,
            activeThumbColor: kGreen,
            onChanged: (v) => setState(() {
              _cornerMustHave = v;
              _recalc();
            }),
          ),
          const Divider(color: TokC.divider, height: 16),
          Text(
            '预览：共 ${_plans.length} 根 · 线路 ${_routeLen.toStringAsFixed(1)} 米'
            '${_plans.length > 1 ? ' · 最大档距 ${_maxSpan.toStringAsFixed(1)} 米' : ''}',
            style: const TextStyle(color: kTextMain, fontSize: TokFs.body),
          ),
          if (_plans.length > 1 && _maxSpan > _spanM * 1.5)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('提示：存在大于 1.5 倍档距的段，请检查拐点设置',
                  style: TextStyle(color: kWarn, fontSize: 12)),
            ),
          const SizedBox(height: 6),
          SizedBox(
            height: 200,
            child: _plans.isEmpty
                ? const Center(
                    child: Text('无杆位', style: TextStyle(color: kTextHint)))
                : ListView.builder(
                    itemCount: _plans.length,
                    itemBuilder: (ctx, i) {
                      final p = _plans[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 76,
                              child: Text(p.name,
                                  style: const TextStyle(
                                      color: kAccent, fontSize: 13)),
                            ),
                            Expanded(
                              child: Text(
                                '${p.lat.toStringAsFixed(6)}, '
                                '${p.lon.toStringAsFixed(6)}',
                                style: const TextStyle(
                                    color: kTextSub, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              darkTextBtn('取消', () => Navigator.pop(context),
                  color: kTextSub),
              const SizedBox(width: 8),
              darkTextBtn(
                _busy ? '写入中…' : '确认布杆',
                _confirm,
                color: kGreen,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
