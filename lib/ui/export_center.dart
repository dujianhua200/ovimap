import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../export/archive_book.dart';
import '../export/csv.dart';
import '../models/diff_report.dart';
import '../models/map_label.dart';
import '../services/store.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'design_tokens.dart';

/// 成果中心（P0-1/P0-3/P0-4）：上下文感知导出 + 一键成册 + 变更对照。
///
/// · [openExportCenter]：编辑时导出草稿、拓扑时导出配线，收敛 4 个导出出口为 1；
/// · [showArchiveBookDialog]：竣工资料一键成册（ZIP，严格 4 项）；
/// · [showDesignDiffDialog]：设计 ↔ 竣工可读变更清单（可导出 CSV）。

/// 上下文感知导出中心：把"谁在什么上下文调 showExportDialog"收敛到一个包装函数。
/// 内部**原样调用** `showExportDialog`（7 种导出一个不动）。
Future<void> openExportCenter(BuildContext context, AppState st) async {
  List<MapLabel> labels;
  String name;
  if (st.mode == AppMode.topoLink) {
    labels = st.topoColl;
    final nm = await st.store.loadCollectionName(st.topoCid);
    name = nm.isEmpty ? '配线' : nm;
  } else if (st.labels.isNotEmpty) {
    labels = st.labels;
    name = st.projectName.isEmpty ? '当前草稿' : st.projectName;
  } else {
    toast(context, '没有可导出的数据');
    return;
  }
  if (!context.mounted) return;
  await showExportDialog(context, labels, name, segPrefix: st.segPrefix);
}

/// 成册对象：当前草稿（[draft]=true）或某个收藏工程。
class _BookOption {
  final String label;
  final String cid;
  final bool draft;
  const _BookOption({required this.label, this.cid = '', this.draft = false});
}

/// 竣工资料一键成册对话框：选工程 → 生成 ZIP → 分享。缺项在说明页标注。
Future<void> showArchiveBookDialog(BuildContext context, AppState st) async {
  final options = <_BookOption>[];
  if (st.labels.isNotEmpty) {
    options.add(_BookOption(
      label: st.projectName.isEmpty ? '当前草稿' : '当前草稿 · ${st.projectName}',
      draft: true,
    ));
  }
  for (final m in st.collections) {
    options.add(
        _BookOption(label: m.name.isEmpty ? '未命名' : m.name, cid: m.id));
  }
  if (options.isEmpty) {
    toast(context, '没有可成册的工程');
    return;
  }
  await showDarkDialog(
    context,
    title: '竣工资料一键成册',
    content: SizedBox(
      width: double.maxFinite,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text(
            '选择工程，一键生成 ZIP：路由图 DXF + 工程量清单 + 材料统计 + 照片册（缺项自动跳过）',
            style: TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 10),
        Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final o in options)
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder_zip_outlined,
                    color: kAccent, size: 20),
                title: Text(o.label,
                    style: const TextStyle(color: kTextMain, fontSize: 13.5)),
                onTap: () {
                  Navigator.pop(context);
                  _runArchiveBook(context, st, o);
                },
              ),
          ]),
        ),
      ]),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

Future<void> _runArchiveBook(
    BuildContext context, AppState st, _BookOption o) async {
  List<MapLabel> labels;
  String name;
  var pointCount = 0;
  String editMode = st.editModeName;
  if (o.draft) {
    labels = st.labels;
    name = st.projectName.isEmpty ? '当前草稿' : st.projectName;
  } else {
    labels = await st.store.loadCollection(o.cid);
    final meta = st.collections.firstWhere(
      (m) => m.id == o.cid,
      orElse: () => CollectionMeta(id: o.cid),
    );
    name = meta.name.isEmpty ? '未命名项目' : meta.name;
    pointCount = meta.count;
    editMode = meta.editMode;
  }
  if (!context.mounted) return;
  if (labels.isEmpty) {
    toast(context, '该工程没有点位');
    return;
  }
  toast(context, '正在生成竣工资料成册…');
  try {
    final r = await ArchiveBookExporter.export(
      name: name,
      labels: labels,
      pointCount: pointCount,
      editMode: editMode,
      segPrefix: st.segPrefix,
    );
    if (!context.mounted) return;
    if (r.skipped.isNotEmpty) {
      toast(context, '成册完成，缺项：${r.skipped.join('、')}');
    } else {
      toast(context, '成册完成：含 ${r.included.length} 项');
    }
    await shareFile(context, r.zip);
  } catch (e) {
    if (context.mounted) toast(context, '成册失败：$e');
  }
}

/// 变更对照对话框：选设计工程 → 可读清单（汇总 + 变更项 + 阈值 + 仅看变更项）
/// → 导出 CSV（复用 `CsvExporter.exportDesignDiff` 口径）。
Future<void> showDesignDiffDialog(
    BuildContext context, AppState st, CollectionMeta completionMeta) async {
  final others =
      st.collections.where((c) => c.id != completionMeta.id).toList();
  if (others.isEmpty) {
    toast(context, '没有可对比的设计工程');
    return;
  }
  await showDarkDialog(
    context,
    title:
        '与「${completionMeta.name.isEmpty ? '未命名' : completionMeta.name}」对比的设计工程',
    content: SizedBox(
      width: double.maxFinite,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('选设计版工程，生成本工程（竣工）与它的杆位/段距差异清单',
            style: TextStyle(color: kTextSub, fontSize: 12)),
        const SizedBox(height: 8),
        Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final c in others)
              ListTile(
                dense: true,
                leading: const Icon(Icons.compare_arrows,
                    color: kAccent, size: 20),
                title: Text(c.name.isEmpty ? '未命名' : c.name,
                    style: const TextStyle(color: kTextMain, fontSize: 13.5)),
                subtitle: Text('${c.count} 点',
                    style: const TextStyle(color: kTextSub, fontSize: 11)),
                onTap: () async {
                  Navigator.pop(context);
                  final comp = await st.store.loadCollection(completionMeta.id);
                  final des = await st.store.loadCollection(c.id);
                  if (!context.mounted) return;
                  await _showDiffReport(
                      context, completionMeta, c, des, comp);
                },
              ),
          ]),
        ),
      ]),
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

Future<void> _showDiffReport(
  BuildContext context,
  CollectionMeta completionMeta,
  CollectionMeta designMeta,
  List<MapLabel> design,
  List<MapLabel> comp,
) async {
  // 阈值记忆：沿用上次选择（showDxfOptions 的 dxf* 口径）；默认 偏移 10m / 段长偏差 5m。
  final prefs = await SharedPreferences.getInstance();
  var offsetThreshold = prefs.getDouble('diffOffsetM') ?? 10.0;
  var segThreshold = prefs.getDouble('diffSegDeltaM') ?? 5.0;
  var onlyChanged = false;
  final offCtl = TextEditingController(text: _fmtM(offsetThreshold));
  final segCtl = TextEditingController(text: _fmtM(segThreshold));
  final name =
      completionMeta.name.isEmpty ? '未命名项目' : completionMeta.name;

  if (!context.mounted) return;
  await showDarkDialog(
    context,
    title: '变更对照：$name',
    content: StatefulBuilder(
      builder: (ctx, setSt) {
        final report = CsvExporter.buildDesignDiff(design, comp,
            offsetThreshold: offsetThreshold);
        final poles =
            onlyChanged ? report.changedPoles : report.poles;
        int byStatus(DiffStatus s) =>
            poles.where((p) => p.status == s).length;
        final added = poles
            .where((p) => p.status == DiffStatus.added)
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        final removed = poles
            .where((p) => p.status == DiffStatus.removed)
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        // 偏移组按偏移量降序：偏差最大的排前面。
        final moved = poles
            .where((p) => p.status == DiffStatus.moved)
            .toList()
          ..sort((a, b) => b.offsetM.compareTo(a.offsetM));
        final same = poles
            .where((p) => p.status == DiffStatus.same)
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        // 段距表按 |差值| 降序：变化最大的杆段排前面。
        final segs = [...report.segs]
          ..sort((a, b) => b.deltaM.abs().compareTo(a.deltaM.abs()));
        final s = report.summary;
        final maxH = MediaQuery.of(ctx).size.height * 0.58;

        void applyThresholds() {
          final o = double.tryParse(offCtl.text.trim());
          final g = double.tryParse(segCtl.text.trim());
          if (o == null || o < 0 || g == null || g < 0) {
            toast(ctx, '阈值无效（需为非负数）');
            return;
          }
          prefs.setDouble('diffOffsetM', o);
          prefs.setDouble('diffSegDeltaM', g);
          setSt(() {
            offsetThreshold = o;
            segThreshold = g;
          });
        }

        return SizedBox(
          width: double.maxFinite,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('设计：${designMeta.name.isEmpty ? '未命名' : designMeta.name}',
                      style: const TextStyle(color: kTextSub, fontSize: 11.5)),
                  const SizedBox(height: 6),
                  _sumRow('新增杆位', '${s.added}', TokC.ok),
                  _sumRow('缺失杆位', '${s.removed}', TokC.danger),
                  _sumRow('偏移杆位', '${s.moved}', TokC.danger),
                  _sumRow('一致杆位', '${s.kept}', kTextSub),
                  _sumRow('净长度差', '${s.netLenDiffM.toStringAsFixed(1)} m',
                      kTextMain),
                  const Divider(color: TokC.divider),
                  // —— 阈值设置（对话框顶部可调，记住上次选择） ——
                  const Text('阈值设置',
                      style: TextStyle(color: kAccent, fontSize: 12.5)),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Text('偏移(米)',
                        style: TextStyle(color: kTextMain, fontSize: 12.5)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: offCtl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style:
                            const TextStyle(color: kTextMain, fontSize: 13),
                        decoration: dec('10'),
                        onSubmitted: (_) => applyThresholds(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text('段长偏差(米)',
                        style: TextStyle(color: kTextMain, fontSize: 12.5)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: segCtl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style:
                            const TextStyle(color: kTextMain, fontSize: 13),
                        decoration: dec('5'),
                        onSubmitted: (_) => applyThresholds(),
                      ),
                    ),
                    TextButton(
                      onPressed: applyThresholds,
                      child: const Text('应用',
                          style: TextStyle(color: kAccent)),
                    ),
                  ]),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅看变更项',
                        style: TextStyle(color: kTextMain, fontSize: 13)),
                    value: onlyChanged,
                    onChanged: (v) => setSt(() => onlyChanged = v),
                  ),
                  const SizedBox(height: 4),
                  // —— 杆位对照：按 新增/缺失/偏移/一致 分组小节 ——
                  const Text('杆位对照',
                      style: TextStyle(color: kAccent, fontSize: 12.5)),
                  if (byStatus(DiffStatus.added) > 0) ...[
                    _diffGroup('新增杆位', added.length, TokC.ok),
                    for (final p in added) _poleRow(p),
                  ],
                  if (byStatus(DiffStatus.removed) > 0) ...[
                    _diffGroup('缺失杆位', removed.length, TokC.danger),
                    for (final p in removed) _poleRow(p),
                  ],
                  if (byStatus(DiffStatus.moved) > 0) ...[
                    _diffGroup('偏移杆位（超 ${offsetThreshold.toStringAsFixed(0)} 米阈值）',
                        moved.length, TokC.danger),
                    for (final p in moved) _poleRow(p),
                  ],
                  if (!onlyChanged && byStatus(DiffStatus.same) > 0) ...[
                    _diffGroup('一致杆位', same.length, kTextSub),
                    for (final p in same) _poleRow(p),
                  ],
                  if (poles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('无变更项',
                          style: TextStyle(color: kTextSub, fontSize: 11.5)),
                    ),
                  const SizedBox(height: 6),
                  // —— 光缆长度变化：同名相邻杆段距对照 ——
                  Text('光缆长度变化（${segs.length} 段）',
                      style: const TextStyle(color: kAccent, fontSize: 12.5)),
                  if (segs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(report.notes.join('；'),
                          style: const TextStyle(
                              color: kTextSub, fontSize: 11.5)),
                    )
                  else
                    for (final seg in segs) _segRow(seg, segThreshold),
                ],
              ),
            ),
          ),
        );
      },
    ),
    actions: [
      darkTextBtn('导出 CSV', () async {
        try {
          final f = await CsvExporter.exportDesignDiff(name, design, comp,
              offsetThreshold: offsetThreshold);
          if (context.mounted) shareFile(context, f);
        } catch (e) {
          if (context.mounted) toast(context, '导出失败：$e');
        }
      }),
      darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
    ],
  );
}

String _fmtM(double v) =>
    v == v.roundToDouble() ? '${v.round()}' : '$v';

/// 偏差表分组小节标题：`名称（n）`。
Widget _diffGroup(String label, int count, Color color) => Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text('$label（$count）',
          style: TextStyle(
              color: color, fontSize: 12.5, fontWeight: FontWeight.bold)),
    );

Widget _sumRow(String label, String value, Color color) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(children: [
        SizedBox(
            width: 88,
            child: Text(label,
                style: const TextStyle(color: kTextSub, fontSize: 12.5))),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 12.5, fontWeight: FontWeight.bold)),
      ]),
    );

Widget _poleRow(DiffPoleItem p) {
  final label = switch (p.status) {
    DiffStatus.added => '新增',
    DiffStatus.removed => '缺失',
    DiffStatus.moved => '偏移',
    DiffStatus.same => '一致',
  };
  // 超标（偏移 > 阈值）红显；边界（= 阈值）时状态为 same，不红。
  final color = switch (p.status) {
    DiffStatus.added => TokC.ok,
    DiffStatus.removed => TokC.danger,
    DiffStatus.moved => TokC.danger,
    DiffStatus.same => kTextSub,
  };
  final extra = switch (p.status) {
    DiffStatus.moved || DiffStatus.same =>
      '　偏移 ${p.offsetM.toStringAsFixed(1)}m',
    _ => '',
  };
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 1.5),
    child: Row(children: [
      SizedBox(
          width: 40,
          child: Text(label,
              style: TextStyle(color: color, fontSize: 12))),
      Expanded(
        child: Text('${p.key}$extra',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kTextMain, fontSize: 12.5)),
      ),
    ]),
  );
}

Widget _segRow(DiffSegItem seg, double segThreshold) {
  // 段长偏差超阈（|Δ| > 阈值）红显；边界（= 阈值）不红。
  final over = diffSegOverThreshold(seg, segThreshold);
  return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(children: [
        Expanded(
          child: Text(seg.seg,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: over ? TokC.danger : kTextMain, fontSize: 12.5)),
        ),
        Text(
            '${seg.designM.toStringAsFixed(1)} → ${seg.compM.toStringAsFixed(1)} '
            '(${seg.deltaM >= 0 ? '+' : ''}${seg.deltaM.toStringAsFixed(1)})',
            style: TextStyle(
                color: over ? TokC.danger : kTextSub, fontSize: 12)),
      ]),
    );
}
