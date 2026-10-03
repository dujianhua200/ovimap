/// 设备分类：通信行业设备模板库。
///
/// 每个分类包含：类型ID、显示名称、编号前缀、默认图标描述。
/// 编号规则：用户自定义优先 → 空白按「前缀+序号」（如 GX-01）。
class DeviceCategory {
  final String typeId;
  final String name;
  final String noPrefix;
  final String iconDesc;

  const DeviceCategory(this.typeId, this.name, this.noPrefix, this.iconDesc);
}

/// 内置设备模板库（行业标准）。
const List<DeviceCategory> kDeviceLibrary = [
  DeviceCategory('olt', 'OLT机房', 'OLT', '房屋形'),
  DeviceCategory('mcab', '室外光交箱', 'GX', '矩形+十字'),
  DeviceCategory('mcab_in', '室内光交箱', 'GX', '矩形+十字'),
  DeviceCategory('fdcab', '分纤箱', 'FH', '矩形'),
  DeviceCategory('termbox', '终端盒/分线盒', 'ZD', '小矩形'),
  DeviceCategory('bsroom', '基站机房', 'JZ', '房屋形'),
  DeviceCategory('cabinet', '综合机柜', 'JG', '矩形'),
  DeviceCategory('leadup', '引上点', 'YS', '三角'),
  DeviceCategory('splice', '接头盒', 'JT', '椭圆'),
  DeviceCategory('pole', '电杆', 'G', '圆圈'),
  DeviceCategory('manhole', '人孔', 'RK', '方形'),
  DeviceCategory('handhole', '手孔', 'SK', '方形'),
  DeviceCategory('odf', 'ODF架', 'ODF', '矩形'),
];

/// 按 typeId 查找分类，未找到返回 null。
DeviceCategory? findCategory(String typeId) {
  for (final c in kDeviceLibrary) {
    if (c.typeId == typeId) return c;
  }
  return null;
}

/// 智能编号：给定已用编号集合，生成下一个可用编号。
/// 如前缀 GX，已有 GX-01/GX-02 → 返回 GX-03。
String nextDeviceNo(String prefix, Set<String> usedNos) {
  var i = 1;
  while (true) {
    final no = '$prefix-${i.toString().padLeft(2, '0')}';
    if (!usedNos.contains(no)) return no;
    i++;
    if (i > 9999) return '$prefix-$i'; // 兜底
  }
}
