import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/export/asbuilt_reports.dart';
import 'package:ovimap/models/fiber_link.dart';
import 'package:ovimap/models/map_label.dart';

void main() {
  MapLabel dev(String id, String name, String type) =>
      MapLabel(id: id, name: name, typeId: type, lat: 32.1, lon: 114.0);

  final devices = [
    dev('a', 'OLT-01', 'olt'),
    dev('b', 'GX-01', 'mcab'),
    dev('c', 'G-01', 'pole'),
  ];
  final links = [
    FiberLink(
        fromDeviceId: 'a',
        toDeviceId: 'b',
        cores: 48,
        cableModel: 'GYTS',
        layMethod: 1,
        lengthM: 100.5),
  ];

  group('AsbuiltReports', () {
    test('fiberLedgerCsv 表头+行', () {
      final csv = AsbuiltReports.fiberLedgerCsv(devices, links);
      expect(csv.contains('序号,起点,终点,芯数'), true);
      expect(csv.contains('OLT-01'), true);
      expect(csv.contains('GX-01'), true);
      expect(csv.contains('48'), true);
      expect(csv.contains('GYTS'), true);
    });

    test('equipmentCsv', () {
      final csv = AsbuiltReports.equipmentCsv(devices);
      expect(csv.contains('OLT-01'), true);
      expect(csv.contains('G-01'), true);
    });

    test('quantitiesCsv 统计', () {
      final csv = AsbuiltReports.quantitiesCsv(devices, links);
      expect(csv.contains('电杆,1,根'), true);
      expect(csv.contains('架空光缆,100.5,米'), true);
    });

    test('materialsCsv 汇总', () {
      final csv = AsbuiltReports.materialsCsv(devices, links);
      expect(csv.contains('48芯GYTS'), true);
      expect(csv.contains('100.5'), true);
    });

    test('空输入不抛异常', () {
      expect(AsbuiltReports.fiberLedgerCsv([], []), contains('序号'));
      expect(AsbuiltReports.quantitiesCsv([], []), contains('电杆,0,根'));
    });

    test('importFiberLinksCsv 往返', () {
      final csv = AsbuiltReports.fiberLedgerCsv(devices, links);
      final imported = AsbuiltReports.importFiberLinksCsv(csv, devices);
      expect(imported.length, 1);
      expect(imported[0].cores, 48);
      expect(imported[0].cableModel, 'GYTS');
      expect(imported[0].layMethod, 1);
      expect(imported[0].lengthM, 100.5);
    });

    test('importFiberLinksCsv 跳过未知设备', () {
      const csv = '序号,起点,终点,芯数,光缆型号,厂家,敷设方式,长度(米),熔接方式,备注\r\n'
          '1,不存在A,不存在B,24,GYTA,,管道,50.0,,\r\n';
      final imported = AsbuiltReports.importFiberLinksCsv(csv, devices);
      expect(imported, isEmpty);
    });
  });
}
