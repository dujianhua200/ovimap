import 'dart:io';

import '../models/device_category.dart';
import '../models/fiber_link.dart';
import '../models/map_label.dart';
import '../services/store.dart';

/// 竣工报表：光缆纤芯台账、设备清单、工程量统计、材料汇总（CSV，Excel/WPS 可直接打开）。
class AsbuiltReports {
  AsbuiltReports._();

  static String _esc(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  /// 1. 光缆纤芯台账
  static String fiberLedgerCsv(
      List<MapLabel> devices, List<FiberLink> links) {
    final byId = {for (final d in devices) d.id: d};
    final sb = StringBuffer();
    sb.write('序号,起点,终点,芯数,光缆型号,厂家,敷设方式,长度(米),熔接方式,备注\r\n');
    var i = 1;
    for (final l in links) {
      final from = byId[l.fromDeviceId];
      final to = byId[l.toDeviceId];
      final fromName = from != null && from.name.isNotEmpty
          ? from.name
          : l.fromDeviceId.substring(
              0, l.fromDeviceId.length > 8 ? 8 : l.fromDeviceId.length);
      final toName = to != null && to.name.isNotEmpty
          ? to.name
          : l.toDeviceId.substring(
              0, l.toDeviceId.length > 8 ? 8 : l.toDeviceId.length);
      sb.write('$i,${_esc(fromName)},${_esc(toName)},${l.cores},'
          '${_esc(l.cableModel)},${_esc(l.manufacturer)},'
          '${_esc(l.layMethodName)},${l.lengthM.toStringAsFixed(1)},'
          '${_esc(l.spliceMethod)},${_esc(l.note)}\r\n');
      i++;
    }
    return sb.toString();
  }

  /// 2. 设备清单
  static String equipmentCsv(List<MapLabel> devices) {
    final sb = StringBuffer();
    sb.write('序号,编号,类型,名称,纬度,经度,备注\r\n');
    var i = 1;
    for (final d in devices) {
      final cat = findCategory(d.typeId);
      final typeName = cat?.name ?? d.typeId;
      sb.write('$i,${_esc(d.name)},${_esc(typeName)},${_esc(d.note)},'
          '${d.lat.toStringAsFixed(8)},${d.lon.toStringAsFixed(8)},'
          '${_esc(d.note)}\r\n');
      i++;
    }
    return sb.toString();
  }

  /// 3. 工程量统计
  static String quantitiesCsv(List<MapLabel> labels, List<FiberLink> links) {
    var poles = 0, manholes = 0, handholes = 0, leadups = 0;
    var aerialLen = 0.0, pipeLen = 0.0, buriedLen = 0.0;
    for (final l in labels) {
      switch (l.typeId) {
        case 'pole':
          poles++;
          break;
        case 'manhole':
          manholes++;
          break;
        case 'handhole':
          handholes++;
          break;
        case 'leadup':
          leadups++;
          break;
      }
    }
    for (final l in links) {
      switch (l.layMethod) {
        case 1:
          aerialLen += l.lengthM;
          break;
        case 2:
          pipeLen += l.lengthM;
          break;
        case 3:
          buriedLen += l.lengthM;
          break;
      }
    }
    final sb = StringBuffer();
    sb.write('项目,数量,单位\r\n');
    sb.write('电杆,$poles,根\r\n');
    sb.write('人孔,$manholes,个\r\n');
    sb.write('手孔,$handholes,个\r\n');
    sb.write('引上点,$leadups,处\r\n');
    sb.write('架空光缆,${aerialLen.toStringAsFixed(1)},米\r\n');
    sb.write('管道光缆,${pipeLen.toStringAsFixed(1)},米\r\n');
    sb.write('直埋光缆,${buriedLen.toStringAsFixed(1)},米\r\n');
    sb.write('光缆总长,${(aerialLen + pipeLen + buriedLen).toStringAsFixed(1)},米\r\n');
    return sb.toString();
  }

  /// 4. 材料汇总（按光缆型号+芯数汇总长度，按设备类型汇总数量）
  static String materialsCsv(List<MapLabel> devices, List<FiberLink> links) {
    final cableLen = <String, double>{};
    for (final l in links) {
      final key = '${l.cores}芯${l.cableModel}'.trim();
      if (key.isEmpty || key == '芯') continue;
      cableLen[key] = (cableLen[key] ?? 0) + l.lengthM;
    }
    final devCount = <String, int>{};
    for (final d in devices) {
      final cat = findCategory(d.typeId);
      final key = cat?.name ?? d.typeId;
      devCount[key] = (devCount[key] ?? 0) + 1;
    }
    final sb = StringBuffer();
    sb.write('类别,规格/类型,数量,单位\r\n');
    for (final e in cableLen.entries) {
      sb.write('光缆,${_esc(e.key)},${e.value.toStringAsFixed(1)},米\r\n');
    }
    for (final e in devCount.entries) {
      sb.write('设备,${_esc(e.key)},${e.value},个\r\n');
    }
    return sb.toString();
  }

  /// 导出全部四张表到文件，返回文件列表。
  static Future<List<File>> exportAll(String name, List<MapLabel> devices,
      List<MapLabel> labels, List<FiberLink> links) async {
    final dir = await LabelStore.instance.exportDir();
    final base = sanitizeName(name);
    final files = <File>[];
    final tables = {
      '光缆纤芯台账': fiberLedgerCsv(devices, links),
      '设备清单': equipmentCsv(devices),
      '工程量统计': quantitiesCsv(labels, links),
      '材料汇总': materialsCsv(devices, links),
    };
    for (final e in tables.entries) {
      final f = File('${dir.path}/${base}_${e.key}.csv');
      // BOM 让 Excel 直接识别中文
      await f.writeAsString('\uFEFF${e.value}');
      files.add(f);
    }
    return files;
  }
}
