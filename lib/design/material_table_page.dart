import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/fav_node.dart';
import '../models/map_label.dart';
import '../services/export_saver.dart';
import '../services/store.dart';
import '../state/fav_tree_controller.dart';
import 'material_table.dart';

/// 材料表页面：范围选择 + 可编辑汇总表 + CSV 导出。
///
/// [node] 为收藏树节点（kind == project 或 folder）；
/// - project：范围可选「当前工程」或「所在文件夹（含子孙）」；
/// - folder：范围为「当前文件夹（含子孙）」。
///
/// 文件夹含子孙的点位收集走 [FavTreeController.projectCidsUnder] +
/// [FavTreeController.labelsOf]（磁盘真相源，不读 overlayLabels）。
class MaterialTablePage extends StatefulWidget {
  const MaterialTablePage({
    super.key,
    required this.controller,
    required this.node,
  });

  final FavTreeController controller;
  final FavNode node;

  @override
  State<MaterialTablePage> createState() => _MaterialTablePageState();
}

enum _ScopeKind { project, folder }

class _ScopeOption {
  const _ScopeOption(this.kind, this.id, this.label);
  final _ScopeKind kind;
  final String id;
  final String label;
}

/// 可编辑行：大类下拉 + 名称/规格/单位文本 + 数量文本。
class _EditRow {
  _EditRow({
    required this.category,
    required String name,
    required String spec,
    required String unit,
    required double quantity,
  })  : nameCtl = TextEditingController(text: name),
        specCtl = TextEditingController(text: spec),
        unitCtl = TextEditingController(text: unit),
        qtyCtl = TextEditingController(text: fmtMaterialQty(quantity));

  String category;
  final TextEditingController nameCtl;
  final TextEditingController specCtl;
  final TextEditingController unitCtl;
  final TextEditingController qtyCtl;

  double get quantity => double.tryParse(qtyCtl.text.trim()) ?? 0;

  MaterialRow toRow() => MaterialRow(
        category: category,
        name: nameCtl.text.trim(),
        spec: specCtl.text.trim(),
        unit: unitCtl.text.trim(),
        quantity: quantity,
      );

  void dispose() {
    nameCtl.dispose();
    specCtl.dispose();
    unitCtl.dispose();
    qtyCtl.dispose();
  }
}

class _MaterialTablePageState extends State<MaterialTablePage> {
  late final List<_ScopeOption> _scopes;
  late _ScopeOption _scope;

  bool _loading = true;
  var _rows = <_EditRow>[];
  var _notes = <String>[];
  var _collectInfo = '';

  @override
  void initState() {
    super.initState();
    final node = widget.node;
    if (node.isProject) {
      _scopes = [
        _ScopeOption(_ScopeKind.project, node.id, '当前工程'),
        _ScopeOption(
          _ScopeKind.folder,
          node.pid,
          node.pid.isEmpty ? '根目录（含子孙）' : '所在文件夹（含子孙）',
        ),
      ];
    } else {
      _scopes = [_ScopeOption(_ScopeKind.folder, node.id, '当前文件夹（含子孙）')];
    }
    _scope = _scopes.first;
    _recompute();
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  /// 按当前范围收集点位（文件夹范围含子孙文件夹下全部工程）。
  Future<List<MapLabel>> _collect() async {
    final c = widget.controller;
    if (_scope.kind == _ScopeKind.project) {
      return c.labelsOf(_scope.id);
    }
    final out = <MapLabel>[];
    for (final cid in c.projectCidsUnder(_scope.id)) {
      out.addAll(await c.labelsOf(cid));
    }
    return out;
  }

  Future<void> _recompute() async {
    setState(() => _loading = true);
    final labels = await _collect();
    if (!mounted) return;
    final summary = buildMaterialSummary(labels);
    for (final r in _rows) {
      r.dispose();
    }
    setState(() {
      _rows = [
        for (final m in summary.rows)
          _EditRow(
            category: m.category,
            name: m.name,
            spec: m.spec,
            unit: m.unit,
            quantity: m.quantity,
          ),
      ];
      _notes = summary.notes;
      _collectInfo = '范围「${_scope.label}」：共 ${labels.length} 个点位';
      _loading = false;
    });
  }

  void _addRow() {
    setState(() {
      _rows.add(_EditRow(
          category: '其它', name: '', spec: '', unit: '', quantity: 0));
    });
  }

  void _deleteRow(int index) {
    setState(() {
      _rows[index].dispose();
      _rows.removeAt(index);
    });
  }

  Future<void> _exportCsv() async {
    final rows = [for (final r in _rows) r.toRow()];
    if (rows.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('材料表为空，无需导出')),
      );
      return;
    }
    final title = '${widget.node.name}·${_scope.label}';
    final text = buildMaterialCsv(title, rows, _notes);
    final dir = await LabelStore.instance.exportDir();
    final file = File('${dir.path}/${sanitizeName(title)}_材料表.csv');
    // UTF-8 BOM，Excel 直接打开不乱码（与现有 CSV 导出一致）。
    await robustWriteBytes(
        file, [0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
    if (!mounted) return;
    await ExportSaver.saveOrShare(context, file);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('材料表 · ${widget.node.name}'),
        actions: [
          IconButton(
            tooltip: '重新计算',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _recompute,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildScopeBar(),
                if (_notes.isNotEmpty) _buildNotes(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Text(_collectInfo,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                const SizedBox(height: 4),
                Expanded(child: _buildTable()),
                _buildBottomBar(),
              ],
            ),
    );
  }

  Widget _buildScopeBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          const Text('范围：'),
          if (_scopes.length > 1)
            SegmentedButton<_ScopeOption>(
              segments: [
                for (final s in _scopes)
                  ButtonSegment(value: s, label: Text(s.label)),
              ],
              selected: {_scope},
              onSelectionChanged: (sel) {
                setState(() => _scope = sel.first);
                _recompute();
              },
            )
          else
            Text(_scopes.first.label,
                style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildNotes() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final n in _notes)
            Text('⚠ $n', style: const TextStyle(color: Colors.amber)),
        ],
      ),
    );
  }

  Widget _buildTable() {
    if (_rows.isEmpty) {
      return const Center(child: Text('暂无材料行，可点下方「新增行」手工录入'));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: _rows.length,
      itemBuilder: (context, i) => _buildRowCard(i),
    );
  }

  Widget _buildRowCard(int index) {
    final r = _rows[index];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                // 大类下拉
                DropdownButton<String>(
                  value: r.category,
                  items: [
                    for (final c in kMaterialCategories)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => r.category = v);
                  },
                ),
                const SizedBox(width: 8),
                // 名称/规格
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: r.nameCtl,
                    decoration:
                        const InputDecoration(labelText: '名称/规格', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                // 数量
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: r.qtyCtl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration:
                        const InputDecoration(labelText: '数量', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                // 单位
                Expanded(
                  child: TextField(
                    controller: r.unitCtl,
                    decoration:
                        const InputDecoration(labelText: '单位', isDense: true),
                  ),
                ),
                IconButton(
                  tooltip: '删除该行',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _deleteRow(index),
                ),
              ],
            ),
            // 规格说明
            TextField(
              controller: r.specCtl,
              decoration:
                  const InputDecoration(labelText: '规格说明', isDense: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('新增行'),
              onPressed: _addRow,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('导出 CSV'),
                onPressed: _exportCsv,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
