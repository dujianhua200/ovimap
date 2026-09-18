import 'package:flutter/material.dart';

import '../../models/map_label.dart';
import '../../geo/geo_util.dart';
import '../../state/app_state.dart';
import '../dialogs.dart';
import 'stats_section.dart';

/// 桌面右栏：选中点属性面板（架构文档 §3.2 / T10）。
///
/// **复用现有属性编辑逻辑**（字段口径、敷设方式枚举、管孔/分光比分支与
/// `showLabelProperties` 一致），仅把容器从「回中对话框」换成常驻侧栏；
/// 照片等重交互仍走 [showLabelProperties]（零逻辑重复）。
///
/// [sourceCid] 为空表示草稿点（走 `st.updateLabel`），否则为可见收藏点
/// （走 `st.updateOverlayLabel`）。
class RightPanel extends StatefulWidget {
  const RightPanel({
    super.key,
    required this.st,
    required this.label,
    required this.sourceCid,
    required this.onCleared,
  });

  final AppState st;
  final MapLabel? label;
  final String sourceCid;

  /// 选中点被删除后回调（壳据此清空选中）。
  final VoidCallback onCleared;

  @override
  State<RightPanel> createState() => _RightPanelState();
}

class _RightPanelState extends State<RightPanel> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _segLabel = TextEditingController();
  final TextEditingController _dist = TextEditingController();
  final TextEditingController _slack = TextEditingController();
  final TextEditingController _segCable = TextEditingController();
  final TextEditingController _holes = TextEditingController();
  final TextEditingController _used = TextEditingController();
  final TextEditingController _ratio = TextEditingController();

  int _segKind = 0;

  AppState get st => widget.st;

  @override
  void initState() {
    super.initState();
    _syncFromWidget();
  }

  @override
  void didUpdateWidget(covariant RightPanel old) {
    super.didUpdateWidget(old);
    // 选中对象变化时重填控件（同一对象被就地修改时不覆盖用户输入）。
    if (widget.label?.id != old.label?.id ||
        widget.sourceCid != old.sourceCid) {
      _syncFromWidget();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    _segLabel.dispose();
    _dist.dispose();
    _slack.dispose();
    _segCable.dispose();
    _holes.dispose();
    _used.dispose();
    _ratio.dispose();
    super.dispose();
  }

  void _syncFromWidget() {
    final l = widget.label;
    _name.text = l?.name ?? '';
    _note.text = l?.note ?? '';
    _segLabel.text = l?.distLabel ?? '';
    _dist.text =
        (l?.distanceM != null && l!.distanceM! > 0) ? l.distanceM!.toStringAsFixed(1) : '';
    _slack.text = (l != null && l.slackM > 0) ? _fmtSlack(l.slackM) : '';
    _segCable.text = l?.segCable ?? '';
    _holes.text = (l != null && l.holes > 0) ? '${l.holes}' : '';
    _used.text = (l != null && l.usedHoles > 0) ? '${l.usedHoles}' : '';
    _ratio.text = l?.splitterRatio ?? '';
    _segKind = l?.segKind ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.label;
    return Container(
      color: const Color(0xFF141920),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text('属性',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                ),
                if (l != null)
                  Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: l.type.color.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                        widget.sourceCid.isEmpty ? '草稿' : '收藏',
                        style: TextStyle(color: l.type.color, fontSize: 10)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: l == null
                ? _empty()
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                    child: _form(context, l),
                  ),
          ),
        ],
      ),
    );
  }

  /// 无选中点：显示提示 + **工程统计**（E1，打开工程/草稿非空时展示）。
  /// `st.labels` 是普通列表（无「未就绪即抛」getter），AOT 安全。
  Widget _empty() {
    final hasData = st.labels.isNotEmpty;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Text(
            '未选中点\n\n在地图上单击一个点，或右键点选「编辑属性」\n即可在此编辑名称 / 段距 / 敷设方式等',
            textAlign: TextAlign.center,
            style: const TextStyle(color: kTextSub, fontSize: 12.5, height: 1.6),
          ),
          if (hasData) ...[
            const SizedBox(height: 14),
            StatsSection(st: st),
          ],
        ],
      ),
    );
  }

  Widget _form(BuildContext context, MapLabel l) {
    final isWell = const ['manhole', 'handwell', 'pipe'].contains(l.typeId);
    final isTopoBox = l.type.isTopoNode;
    final showSeg = l.seq > 1 && l.typeId != 'text' && l.typeId != 'track';
    // 段标注 chip 自动补距离：取同线组上一链点的段距（与地图渲染口径一致）。
    final _prevSeg = st.previousChainLabel(l);
    final _autoSegDist = _prevSeg == null
        ? null
        : (l.distanceM ??
            GeoUtil.haversine(_prevSeg.lat, _prevSeg.lon, l.lat, l.lon));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('类型：${l.type.name}　#${l.seq}',
            style: const TextStyle(color: kTextSub, fontSize: 11)),
        const SizedBox(height: 8),
        TextField(
            controller: _name,
            style: const TextStyle(color: kTextMain, fontSize: 13.5),
            decoration: dec('名称')),
        const SizedBox(height: 8),
        TextField(
            controller: _note,
            maxLines: 2,
            style: const TextStyle(color: kTextMain, fontSize: 13.5),
            decoration: dec('备注')),
        if (showSeg) ...[
          const SizedBox(height: 10),
          const Text('本段标注',
              style: TextStyle(color: kTextSub, fontSize: 11)),
          const SizedBox(height: 4),
          TextField(
              controller: _segLabel,
              style: const TextStyle(color: kTextMain, fontSize: 13.5),
              decoration: dec('如：埋42.5 / 架38，留空自动显示距离')),
          const SizedBox(height: 6),
          segPrefixChips(_segLabel, autoDist: _autoSegDist),
          const SizedBox(height: 8),
          TextField(
              controller: _dist,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: kTextMain, fontSize: 13.5),
              decoration: dec('到上一点距离（米，留空自动）')),
          const SizedBox(height: 8),
          TextField(
              controller: _slack,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: kTextMain, fontSize: 13.5),
              decoration: dec('本段接头盘留（米）')),
          const SizedBox(height: 8),
          TextField(
              controller: _segCable,
              style: const TextStyle(color: kTextMain, fontSize: 13.5),
              decoration: dec('本段光缆型号（如 48芯GYTS）')),
          const SizedBox(height: 8),
          const Text('本段敷设方式（决定连线颜色）',
              style: TextStyle(color: kTextSub, fontSize: 11)),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final kv in const {
                0: '默认',
                1: '架空',
                2: '埋地',
                3: '管道',
              }.entries)
                ChoiceChip(
                  label: Text(kv.value,
                      style: TextStyle(
                          color: _segKind == kv.key ? Colors.black : kTextMain,
                          fontSize: 12)),
                  selected: _segKind == kv.key,
                  selectedColor: kAccent,
                  backgroundColor: const Color(0xFF232A31),
                  side: BorderSide.none,
                  onSelected: (_) => setState(() => _segKind = kv.key),
                ),
            ],
          ),
        ],
        if (isWell) ...[
          const SizedBox(height: 10),
          const Text('管孔（可选）', style: TextStyle(color: kTextSub, fontSize: 11)),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: _holes,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: kTextMain, fontSize: 13.5),
                    decoration: dec('总孔数'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: _used,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: kTextMain, fontSize: 13.5),
                    decoration: dec('已占用'))),
          ]),
        ],
        if (isTopoBox) ...[
          const SizedBox(height: 10),
          TextField(
              controller: _ratio,
              style: const TextStyle(color: kTextMain, fontSize: 13.5),
              decoration: dec('分光比（如 1:8 / 1:16）')),
        ],
        const SizedBox(height: 14),
        _actions(context, l),
      ],
    );
  }

  Widget _actions(BuildContext context, MapLabel l) {
    final draft = widget.sourceCid.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _save(context, l),
              icon: const Icon(Icons.save, size: 16),
              label: const Text('保存', style: TextStyle(fontSize: 12.5)),
              style: FilledButton.styleFrom(
                  backgroundColor: kAccent.withValues(alpha: 0.9),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 10)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _delete(context, l),
              icon: const Icon(Icons.delete_outline,
                  size: 16, color: Color(0xFFFF5252)),
              label: const Text('删除点',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFFFF5252))),
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFFF5252)),
                  padding: const EdgeInsets.symmetric(vertical: 10)),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (draft &&
            l.typeId != 'text' &&
            l.typeId != 'track')
          _wide('从此点续画分支', Icons.call_split, () {
            st.setMode(AppMode.edit);
            st.startRouteFrom(l);
            toast(context, '已从「${_nm(l)}」开始新分支杆路，继续点地图绘制');
          }),
        if (draft)
          _wide('拖动点位', Icons.open_with, () {
            st.draggingLabelId = l.id;
            st.refreshUi();
            toast(context, '拖动模式：在地图上点一下，把「${_nm(l)}」移到那里');
          }),
        if (st.hasFix && st.curLat != null && st.curLon != null)
          _wide('移到当前定位', Icons.my_location, () {
            l.lat = st.curLat!;
            l.lon = st.curLon!;
            if (draft) {
              st.updateLabel(l);
            } else {
              st.updateOverlayLabel(widget.sourceCid, l);
            }
            toast(context, '已把「${_nm(l)}」移到当前定位位置');
          }),
        _wide('完整属性（含照片）…', Icons.photo_camera_back, () {
          showLabelProperties(context, st, l,
              sourceCid: widget.sourceCid,
              title: _nm(l));
        }),
      ],
    );
  }

  Widget _wide(String text, IconData icon, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 15, color: kTextMain),
          label: Align(
              alignment: Alignment.centerLeft,
              child: Text(text,
                  style: const TextStyle(color: kTextMain, fontSize: 12.5))),
          style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              alignment: Alignment.centerLeft),
        ),
      );

  Future<void> _save(BuildContext context, MapLabel l) async {
    l.name = _name.text.trim();
    l.note = _note.text.trim();
    l.segKind = _segKind;
    l.distLabel = _segLabel.text.trim();
    final d = double.tryParse(_dist.text.trim());
    l.distanceM = (d != null && d > 0) ? d : null;
    final sk = double.tryParse(_slack.text.trim());
    l.slackM = (sk != null && sk > 0) ? sk : 0;
    l.segCable = _segCable.text.trim();
    l.holes = int.tryParse(_holes.text.trim()) ?? 0;
    l.usedHoles = int.tryParse(_used.text.trim()) ?? 0;
    l.splitterRatio = _ratio.text.trim();
    if (widget.sourceCid.isEmpty) {
      st.updateLabel(l);
    } else {
      await st.updateOverlayLabel(widget.sourceCid, l);
    }
    if (context.mounted) toast(context, '已保存「${_nm(l)}」');
  }

  Future<void> _delete(BuildContext context, MapLabel l) async {
    if (widget.sourceCid.isEmpty) {
      st.removeLabel(l);
    } else {
      await st.removeOverlayLabel(widget.sourceCid, l);
    }
    widget.onCleared();
  }

  String _nm(MapLabel l) => l.name.trim().isNotEmpty ? l.name.trim() : l.type.name;
}

String _fmtSlack(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
