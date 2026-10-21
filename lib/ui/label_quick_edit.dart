import 'package:flutter/material.dart';

import '../geo/geo_util.dart';
import '../models/map_label.dart';
import '../state/app_state.dart';
import 'design_tokens.dart';
import 'dialogs.dart';
import 'label_marker.dart';

/// 两段式点选第二次点击弹出的紧凑编辑小框 + 标签样式选择器（三端共用）。
///
/// 与完整属性框 [showLabelProperties] 同一批高频字段、同一保存通路
/// （草稿走 `updateLabel`、叠加点走 `updateOverlayLabel`，撤销语义不变）；
/// 低频字段（照片 / 管孔 / 分光比 / 光缆型号）仍在完整框里，小框「更多」直达。

/// 盘留数字显示：整数不带小数点，否则保留 1 位（与完整属性框同口径）。
String _fmtSlack(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// 在给定点表内按链口径找上一链点（与 `AppState.previousChainLabel` 同规则，
/// 叠加点不在草稿表里，故在本文件内对所属工程点表做同一查找）。
MapLabel? _prevInList(List<MapLabel> list, MapLabel l) {
  final idx = list.indexWhere((e) => e.id == l.id);
  for (var i = idx - 1; i >= 0; i--) {
    final e = list[i];
    if (!isLineMember(e)) continue;
    if (l.lineGroupId.isEmpty || e.lineGroupId == l.lineGroupId) return e;
  }
  return null;
}

/// 标签属性快速编辑小框：名称 / 段距离+标注 / 敷设方式 / 盘留 / 符号样式 / 备注。
///
/// [sourceCid] 空串 = 草稿点；非空 = 该收藏工程的叠加点（保存/删除走 overlay 通路）。
Future<void> showLabelQuickEdit(
  BuildContext context,
  AppState st,
  MapLabel label, {
  String sourceCid = '',
}) async {
  final nameCtl = TextEditingController(text: label.name);
  final noteCtl = TextEditingController(text: label.note);
  final segLabelCtl = TextEditingController(text: label.distLabel);
  final distCtl = TextEditingController(
    text: label.distanceM != null ? label.distanceM!.toStringAsFixed(1) : '',
  );
  final slackCtl = TextEditingController(
    text: label.slackM > 0 ? _fmtSlack(label.slackM) : '',
  );
  var segKind = label.segKind;
  // 待保存的样式覆盖（选择器改这里，「保存」才写回 label）。
  var symColor = label.symColor;
  var symShape = label.symShape;
  var symText = label.symText;

  // 上一链点与自动距离（占位显示 + chip 自动补数，与地图渲染同口径）。
  final MapLabel? prev = sourceCid.isEmpty
      ? st.previousChainLabel(label)
      : _prevInList(st.overlayLabels[sourceCid] ?? const [], label);
  final double? autoDist = prev == null
      ? label.distanceM
      : (label.distanceM ??
            GeoUtil.haversine(prev.lat, prev.lon, label.lat, label.lon));
  final showSeg = label.seq > 1 || prev != null;

  // 距离框改动后重建内容，让 segPrefixChips 的自动补数跟随距离框现值。
  void Function(void Function())? dlgSetSt;
  distCtl.addListener(() => dlgSetSt?.call(() {}));

  MapLabel stylePreview() {
    final p = label.clone()
      ..symColor = symColor
      ..symShape = symShape
      ..symText = symText
      ..name = ''; // 预览只看符号本身（名称在上方输入框里）
    return p;
  }

  await showDarkDialog(
    context,
    title: label.name.trim().isNotEmpty ? label.name.trim() : label.type.name,
    width: 420,
    content: StatefulBuilder(
      builder: (ctx, setSt) {
        dlgSetSt = setSt;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtl,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('标签名称'),
              ),
              if (showSeg) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: distCtl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(color: kTextMain, fontSize: 14),
                  decoration: dec(
                    autoDist == null
                        ? '到上一点距离（米，留空自动）'
                        : '到上一点距离（米，留空=自动 ${GeoUtil.segDistText(autoDist)}）',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: segLabelCtl,
                  style: const TextStyle(color: kTextMain, fontSize: 14),
                  decoration: dec('本段标注（如：埋42.5 / 架38，留空自动显示距离）'),
                ),
                const SizedBox(height: 6),
                // chip 自动补数：标注框已有数字优先，否则用距离框现值，
                // 再退自动距离（与完整属性框 segPrefixChips 同一口径）。
                segPrefixChips(
                  segLabelCtl,
                  autoDist: double.tryParse(distCtl.text.trim()) ?? autoDist,
                ),
                const SizedBox(height: 8),
                const Text(
                  '本段敷设方式（决定连线颜色）',
                  style: TextStyle(color: kTextSub, fontSize: 11),
                ),
                Row(
                  children: [
                    for (final kv in const {
                      0: '默认',
                      1: '架空',
                      2: '埋地',
                      3: '管道',
                    }.entries)
                      Expanded(
                        child: RadioListTile<int>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            kv.value,
                            style: const TextStyle(
                              color: kTextMain,
                              fontSize: 12,
                            ),
                          ),
                          value: kv.key,
                          groupValue: segKind,
                          activeColor: kAccent,
                          onChanged: (v) => setSt(() => segKind = v!),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: slackCtl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(color: kTextMain, fontSize: 14),
                  decoration: dec('本段接头盘留（米，结算用量=丈量+盘留）'),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text(
                    '符号样式',
                    style: TextStyle(color: kTextSub, fontSize: 12),
                  ),
                  const SizedBox(width: 12),
                  LabelSymbol(label: stylePreview()),
                  const Spacer(),
                  darkTextBtn('样式…', () async {
                    final r = await showLabelStylePicker(ctx, stylePreview());
                    if (r != null) {
                      setSt(() {
                        symColor = r.$1;
                        symShape = r.$2;
                        symText = r.$3;
                      });
                    }
                  }),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteCtl,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('备注'),
              ),
            ],
          ),
        );
      },
    ),
    actions: [
      darkTextBtn('删除点', () {
        Navigator.pop(context);
        if (sourceCid.isEmpty) {
          st.removeLabel(label);
        } else {
          st.removeOverlayLabel(sourceCid, label);
        }
      }, color: TokC.danger),
      darkTextBtn('更多', () {
        Navigator.pop(context);
        showLabelProperties(
          context,
          st,
          label,
          sourceCid: sourceCid,
          title: label.name.trim().isNotEmpty
              ? label.name.trim()
              : label.type.name,
        );
      }, color: kTextSub),
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('保存', () {
        label.name = nameCtl.text.trim();
        label.note = noteCtl.text.trim();
        label.distLabel = segLabelCtl.text.trim();
        final d = double.tryParse(distCtl.text.trim());
        label.distanceM = (d != null && d > 0) ? d : null;
        final sk = double.tryParse(slackCtl.text.trim());
        label.slackM = (sk != null && sk > 0) ? sk : 0;
        label.segKind = segKind;
        label.symColor = symColor;
        label.symShape = symShape;
        label.symText = symText;
        Navigator.pop(context);
        if (sourceCid.isEmpty) {
          st.updateLabel(label);
        } else {
          st.updateOverlayLabel(sourceCid, label);
        }
      }),
    ],
  );
}

/// 样式可选形状（值与 `MapLabel.symShape` 口径一致）。
const List<(String, String)> kSymShapes = [
  ('pin', '水滴'),
  ('oval', '椭圆'),
  ('box', '方框'),
  ('tri', '三角'),
  ('dot', '圆点'),
];

/// 样式预置色板（12 色：类型库主色为主）。
const List<int> kSymPalette = [
  0xFF1565C0, // 管道口蓝
  0xFF6A1B9A, // 水泥杆紫
  0xFF5D4037, // 木杆棕
  0xFFE53935, // 电力杆红
  0xFF00838F, // 人孔青
  0xFFEF6C00, // 手井橙
  0xFF2E7D32, // 分纤盒绿
  0xFF00695C, // 分光器深青
  0xFF3949AB, // ONU 靛蓝
  0xFFAD1457, // 交接箱玫红
  0xFF455A64, // 机房灰蓝
  0xFFFFC107, // 轨迹黄
];

/// 标签样式选择器：5 形状 × 12 色网格（格子即迷你符号预览）+ 符号字 + 跟随类型重置。
///
/// 返回 `(symColor, symShape, symText)` 覆盖三元组；取消返回 null。
/// 三项均为缺省值（0 / '' / ''）表示「跟随类型」。
Future<(int, String, String)?> showLabelStylePicker(
  BuildContext context,
  MapLabel label,
) async {
  var selColor = label.symColor;
  var selShape = label.symShape;
  final textCtl = TextEditingController(text: label.symText);
  (int, String, String)? result;

  void Function(void Function())? dlgSetSt;
  textCtl.addListener(() => dlgSetSt?.call(() {}));

  // 网格/预览共用：套候选覆盖的样例标签，走 LabelSymbol 同一绘制路径。
  MapLabel sample(int color, String shape) => label.clone()
    ..symColor = color
    ..symShape = shape
    ..symText = textCtl.text.trim()
    ..name = '';

  await showDarkDialog(
    context,
    title: '标签样式',
    width: 470,
    content: StatefulBuilder(
      builder: (ctx, setSt) {
        dlgSetSt = setSt;
        final following = selColor == 0 && selShape.isEmpty;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '当前',
                    style: TextStyle(color: kTextSub, fontSize: 12),
                  ),
                  const SizedBox(width: 12),
                  LabelSymbol(label: sample(selColor, selShape)),
                  const SizedBox(width: 12),
                  Text(
                    following ? '跟随类型' : '自定义',
                    style: const TextStyle(color: kTextSub, fontSize: 12),
                  ),
                  const Spacer(),
                  darkTextBtn('跟随类型', () {
                    setSt(() {
                      selColor = 0;
                      selShape = '';
                      textCtl.text = '';
                    });
                  }, color: kTextSub),
                ],
              ),
              const SizedBox(height: 10),
              for (final (shape, shapeName) in kSymShapes) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(
                        shapeName,
                        style: const TextStyle(color: kTextSub, fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final color in kSymPalette)
                            GestureDetector(
                              onTap: () => setSt(() {
                                selColor = color;
                                selShape = shape;
                              }),
                              child: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: TokC.field,
                                  borderRadius: BorderRadius.circular(TokR.s),
                                  border: Border.all(
                                    color:
                                        selColor == color && selShape == shape
                                        ? kAccent
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: Center(
                                  child: LabelSymbol(
                                    label: sample(color, shape),
                                    scale: 0.82,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              const SizedBox(height: 4),
              TextField(
                controller: textCtl,
                maxLength: 2,
                style: const TextStyle(color: kTextMain, fontSize: 14),
                decoration: dec('符号字（≤2 字，留空跟随类型）'),
              ),
            ],
          ),
        );
      },
    ),
    actions: [
      darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      darkTextBtn('确定', () {
        result = (selColor, selShape, textCtl.text.trim());
        Navigator.pop(context);
      }),
    ],
  );
  return result;
}
