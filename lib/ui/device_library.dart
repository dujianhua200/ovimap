/// 设备模板库 UI（Phase 4）：13 类设备模板选择器 + 智能编号 + 批量改号。
///
/// - [showDeviceTemplatePicker]：从地图"添加设备"时弹出的模板选择器；
/// - [createDeviceFromTemplate]：按模板创建 MapLabel（typeId 映射到最近的
///   LabelType 以便渲染，原始分类 id 存入 extra['deviceCategory']）；
/// - [renumberDevices]：批量改号（按类型前缀重新编号）。
library;

import 'package:flutter/material.dart';
import 'package:ovimap/models/device_category.dart';
import 'package:ovimap/models/label_type.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/ui/design_tokens.dart';

/// 设备分类 → 最近的 LabelType（渲染用符号/颜色）。
///
/// MapLabel.typeId 必须是 LabelType.all 中存在的 id，否则回退为 pipe。
const Map<String, String> kCategoryToLabelType = {
  'olt': 'room', // OLT机房 → 机房
  'mcab': 'crossbox', // 室外光交箱 → 交接箱
  'mcab_in': 'crossbox', // 室内光交箱 → 交接箱
  'fdcab': 'fiberbox', // 分纤箱 → 分纤盒
  'termbox': 'fiberbox', // 终端盒/分线盒 → 分纤盒
  'bsroom': 'bts', // 基站机房 → 基站
  'cabinet': 'room', // 综合机柜 → 机房
  'leadup': 'riser', // 引上点 → 引上
  'splice': 'splitterbox', // 接头盒 → 分光器箱
  'pole': 'concrete', // 电杆 → 水泥杆
  'manhole': 'manhole', // 人孔 → 人孔
  'handhole': 'handwell', // 手孔 → 手井
  'odf': 'fiberbox', // ODF架 → 分纤盒
};

/// 设备模板选择器（底部弹层，13 类网格）。
///
/// 返回用户选中的 [DeviceCategory]，取消返回 null。
Future<DeviceCategory?> showDeviceTemplatePicker(BuildContext context) {
  return showModalBottomSheet<DeviceCategory>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: TokSp.titlePad,
            child: Text('选择设备模板',
                style: TextStyle(
                    fontSize: TokFs.heading, fontWeight: FontWeight.bold)),
          ),
          Flexible(
            child: GridView.builder(
              shrinkWrap: true,
              padding: TokSp.panelPad,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: TokSp.s,
                crossAxisSpacing: TokSp.s,
                childAspectRatio: 0.85,
              ),
              itemCount: kDeviceLibrary.length,
              itemBuilder: (_, i) {
                final c = kDeviceLibrary[i];
                final labelTypeId = kCategoryToLabelType[c.typeId] ?? 'pipe';
                final lt = LabelType.fromId(labelTypeId);
                return InkWell(
                  key: ValueKey('tpl_${c.typeId}'),
                  borderRadius: BorderRadius.circular(TokR.m),
                  onTap: () => Navigator.pop(ctx, c),
                  child: Container(
                    decoration: BoxDecoration(
                      color: TokC.card,
                      borderRadius: BorderRadius.circular(TokR.m),
                      border: Border.all(color: TokC.divider),
                    ),
                    padding: const EdgeInsets.all(TokSp.xs),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: lt.color.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(TokR.s),
                            border: Border.all(color: lt.color, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            c.noPrefix,
                            style: TextStyle(
                              fontSize: TokFs.micro,
                              fontWeight: FontWeight.bold,
                              color: lt.color,
                            ),
                          ),
                        ),
                        const SizedBox(height: TokSp.xs),
                        Text(
                          c.name,
                          style: const TextStyle(fontSize: TokFs.micro),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// 按模板创建设备 MapLabel。
///
/// - [category] 选中的设备模板；
/// - [lat]/[lon] 落点经纬度；
/// - [existing] 当前工程已有标签（用于智能编号避重）；
/// - [customName] 用户自定义名称（非空时优先，不自动编号）；
/// - [seq] 序号。
///
/// 编号规则：用户自定义优先 → 空白按「前缀+序号」（如 GX-01）。
MapLabel createDeviceFromTemplate({
  required DeviceCategory category,
  required double lat,
  required double lon,
  List<MapLabel> existing = const [],
  String? customName,
  int seq = 1,
}) {
  final used = {for (final l in existing) l.name};
  final name = (customName != null && customName.trim().isNotEmpty)
      ? customName.trim()
      : nextDeviceNo(category.noPrefix, used);
  return MapLabel(
    typeId: kCategoryToLabelType[category.typeId] ?? 'pipe',
    seq: seq,
    lat: lat,
    lon: lon,
    name: name,
    extra: {'deviceCategory': category.typeId},
  );
}

/// 取设备的编号前缀：优先 extra 中的原始分类，否则按 typeId 直查。
String deviceNoPrefix(MapLabel l) {
  final catId = l.extra?['deviceCategory'] as String?;
  final cat = catId != null ? findCategory(catId) : null;
  if (cat != null) return cat.noPrefix;
  return findCategory(l.typeId)?.noPrefix ?? 'SB';
}

/// 批量改号：[selectedIds] 中的设备按各自类型前缀重新编号。
///
/// 编号避开未选中设备的已有名称；选中设备按 id 排序后依次编号，
/// 保证结果确定、可单测。直接修改 [all] 中对应 MapLabel 的 name。
void renumberDevices(List<MapLabel> all, Set<String> selectedIds) {
  if (selectedIds.isEmpty) return;
  final used = {
    for (final l in all)
      if (!selectedIds.contains(l.id) && l.name.trim().isNotEmpty)
        l.name.trim()
  };
  final selected = [for (final l in all) if (selectedIds.contains(l.id)) l]
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final l in selected) {
    final no = nextDeviceNo(deviceNoPrefix(l), used);
    l.name = no;
    used.add(no);
  }
}

/// 批量改号确认对话框。返回 true 表示确认执行。
Future<bool> showBatchRenumberConfirm(BuildContext context, int count) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('批量改号'),
      content: Text('将 $count 个选中设备按类型重新编号（如 GX-01、FH-01）？\n原有自定义编号将被覆盖。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('重新编号'),
        ),
      ],
    ),
  );
  return ok == true;
}
