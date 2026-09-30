/// 光缆配盘表页面：参数表单 + 重新计算 + 结果表 + CSV 导出。
///
/// 入口数据来自所属工程的 chains（见 [buildCableSegsFromLabels]）；
/// 交付走 [ExportSaver]（桌面另存为 / 移动端分享），不碰任何导出细节。
library;

import 'package:flutter/material.dart';

import '../export/csv.dart';
import '../models/map_label.dart';
import '../services/export_saver.dart';
import '../ui/dialogs.dart';
import 'drum_plan.dart';

/// 光缆配盘表页面。
///
/// [projectName] 工程名（表头/文件名用）；[labels] 工程全部点位，
/// 页面内部按 chains 拆段。
class DrumPlanPage extends StatefulWidget {
  const DrumPlanPage({
    super.key,
    required this.projectName,
    required this.labels,
  });

  final String projectName;
  final List<MapLabel> labels;

  @override
  State<DrumPlanPage> createState() => _DrumPlanPageState();
}

class _DrumPlanPageState extends State<DrumPlanPage> {
  final _drumLenCtl = TextEditingController(text: '2000');
  final _spliceCtl = TextEditingController(text: '15');
  final _riserCtl = TextEditingController(text: '15');
  final _minRemnantCtl = TextEditingController(text: '100');
  String _layingMethod = drumLayingMethods.first;
  bool _countRiser = true;

  late List<CableSeg> _segs;
  List<DrumPlan> _plans = [];
  DrumPlanParams _params = const DrumPlanParams();

  @override
  void initState() {
    super.initState();
    _segs = buildCableSegsFromLabels(widget.labels);
    _recalc();
  }

  @override
  void dispose() {
    _drumLenCtl.dispose();
    _spliceCtl.dispose();
    _riserCtl.dispose();
    _minRemnantCtl.dispose();
    super.dispose();
  }

  double _num(TextEditingController c, double fallback) {
    final v = double.tryParse(c.text.trim());
    return (v == null || v <= 0) ? fallback : v;
  }

  /// 按当前参数重新计算。
  void _recalc() {
    final p = DrumPlanParams(
      drumLengthM: _num(_drumLenCtl, 2000),
      spliceSlackM: _num(_spliceCtl, 15),
      riserSlackM: _num(_riserCtl, 15),
      countRiserSlack: _countRiser,
      layingMethod: _layingMethod,
      minRemnantM: _num(_minRemnantCtl, 100),
    );
    setState(() {
      _params = p;
      _plans = planDrums(_segs, p);
    });
  }

  Future<void> _export() async {
    try {
      final f = await CsvExporter.exportDrumPlan(
          widget.projectName, _plans, _params);
      if (!mounted) return;
      await ExportSaver.saveOrShare(context, f,
          suggestedName: f.uri.pathSegments.last);
    } catch (e) {
      if (mounted) toast(context, '导出配盘表失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final missing =
        _segs.where((s) => isUnsetCableModel(s.cableModel)).toList();
    final totalNeed =
        _segs.fold<double>(0, (a, s) => a + _params.demandOf(s));

    return Scaffold(
      appBar: AppBar(
        title: Text('光缆配盘表 · ${widget.projectName}'),
        actions: [
          TextButton.icon(
            onPressed: _plans.isEmpty ? null : _export,
            icon: const Icon(Icons.ios_share),
            label: const Text('导出 CSV'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _paramCard(context),
            const SizedBox(height: 12),
            if (missing.isNotEmpty) _missingBanner(context, missing),
            if (missing.isNotEmpty) const SizedBox(height: 12),
            _resultCard(context, tt, totalNeed),
          ],
        ),
      ),
    );
  }

  Widget _paramCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('计算参数（共 ${_segs.length} 段）',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _numField('单盘盘长（米）', _drumLenCtl),
                _numField('接头预留（米/处）', _spliceCtl),
                _numField('引上预留（米/处）', _riserCtl),
                _numField('余缆告警阈值（米）', _minRemnantCtl),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('敷设方式：'),
                DropdownButton<String>(
                  value: _layingMethod,
                  items: [
                    for (final m in drumLayingMethods)
                      DropdownMenuItem(value: m, child: Text(m)),
                  ],
                  onChanged: (v) =>
                      setState(() => _layingMethod = v ?? _layingMethod),
                ),
                const SizedBox(width: 16),
                Checkbox(
                  value: _countRiser,
                  onChanged: (v) =>
                      setState(() => _countRiser = v ?? true),
                ),
                const Text('计入引上预留'),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _recalc,
              icon: const Icon(Icons.calculate),
              label: const Text('重新计算'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _numField(String label, TextEditingController ctl) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: ctl,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _missingBanner(BuildContext context, List<CableSeg> missing) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('⚠ ${missing.length} 段未填光缆型号（已按“未填型号”单独装盘）：',
                style: TextStyle(
                    color: cs.onErrorContainer,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(missing.map((s) => s.label).join('、'),
                style: TextStyle(color: cs.onErrorContainer)),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(
      BuildContext context, TextTheme tt, double totalNeed) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('配盘结果：共 ${_plans.length} 盘，'
                '光缆总需求 ${totalNeed.toStringAsFixed(1)} 米（含预留）',
                style: tt.titleSmall),
            const SizedBox(height: 8),
            if (_plans.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('无段落数据')),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('盘号')),
                    DataColumn(label: Text('段落范围')),
                    DataColumn(label: Text('光缆型号')),
                    DataColumn(label: Text('盘长(m)')),
                    DataColumn(label: Text('利用率')),
                    DataColumn(label: Text('告警')),
                  ],
                  rows: [
                    for (final d in _plans)
                      DataRow(cells: [
                        DataCell(Text('${d.drumNo}')),
                        DataCell(Text(d.segs)),
                        DataCell(Text(d.cableModel)),
                        DataCell(Text(
                            '${d.usedM.toStringAsFixed(1)}/${d.drumLengthM.toStringAsFixed(0)}')),
                        DataCell(Text(
                            '${(d.utilization * 100).toStringAsFixed(1)}%')),
                        DataCell(
                          Text(
                            d.warnings.isEmpty ? '—' : d.warnings.join('\n'),
                            style: d.warnings.isEmpty
                                ? null
                                : TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .error,
                                  ),
                          ),
                        ),
                      ]),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
