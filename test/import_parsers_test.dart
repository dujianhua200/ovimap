import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/import/import_model.dart';
import 'package:ovimap/import/importer.dart';
import 'package:ovimap/import/kml_parser.dart';
import 'package:ovimap/import/kmz_parser.dart';
import 'package:ovimap/import/ovjsn_parser.dart';
import 'package:ovimap/import/ovobj_parser.dart';

// GCJ-02 (39.9042, 116.4074) → WGS-84（由 lib/geo/gcj02.dart 预计算的黄金值）
const _wgsLatA = 39.90279624501254;
const _wgsLonA = 116.40115682527856;
// GCJ-02 (32.1301, 114.0814) → WGS-84
const _wgsLatB = 32.13205202433858;
const _wgsLonB = 114.075514589886;

// UTF-8 BOM（ovjsn 文件头常见）
const _bom = '\uFEFF';

const _kmlSample = '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>测试文档</name>
  <Folder>
    <name>北京</name>
    <Folder>
      <name>朝阳</name>
      <Placemark>
        <name>杆1</name>
        <description><![CDATA[备注A]]></description>
        <OvCoordType>GCJ02</OvCoordType>
        <Point><coordinates>116.407400,39.904200,0</coordinates></Point>
      </Placemark>
      <Placemark>
        <name>线1</name>
        <LineString><coordinates>116.407400,39.904200 116.408400,39.905200</coordinates></LineString>
      </Placemark>
      <Placemark>
        <name>面1</name>
        <Polygon><outerBoundaryIs><LinearRing><coordinates>116.410000,39.900000 116.420000,39.900000 116.420000,39.910000 116.410000,39.910000</coordinates></LinearRing></outerBoundaryIs></Polygon>
      </Placemark>
    </Folder>
    <Placemark>
      <name>北京直属点</name>
      <Point><coordinates>116.397000,39.907000</coordinates></Point>
    </Placemark>
  </Folder>
  <Placemark>
    <name>根点</name>
    <Point><coordinates>114.081400,32.130100</coordinates></Point>
  </Placemark>
</Document>
</kml>
''';

ImportUnit _unitOf(ImportParseResult r, List<String> path) =>
    r.units.firstWhere((u) => u.folderPath.join('/') == path.join('/'));

void main() {
  group('KmlParser', () {
    test('两层 Folder 嵌套 + description + OvCoordType=GCJ02', () {
      final r = KmlParser.parse(_kmlSample);

      expect(r.units.length, 3);
      expect(r.detectedSystem, 'GCJ02');

      // 朝阳：两层路径、单元名为直接父 Folder
      final cy = _unitOf(r, ['北京', '朝阳']);
      expect(cy.name, '朝阳');
      expect(cy.description, contains('备注A'));

      // 杆1：GCJ-02 → WGS-84 转换
      final p1 = cy.labels.firstWhere((l) => l.name == '杆1');
      expect(p1.lat, closeTo(_wgsLatA, 1e-9));
      expect(p1.lon, closeTo(_wgsLonA, 1e-9));
      expect(p1.note, '备注A');
      expect(p1.lineGroupId, isEmpty);

      // 线1：WGS-84 原样、独立 lineGroupId
      final line = cy.labels.where((l) => l.lineGroupId.isNotEmpty).toList();
      final lineGids = line.map((l) => l.lineGroupId).toSet();
      expect(lineGids.length, 2); // 线1 与面1 各自一组
      final line1 = line
          .where((l) => l.lineGroupId == line.first.lineGroupId)
          .toList();
      expect(line1.length, 2);
      expect(line1[0].name, '线1');
      expect(line1[0].lat, 39.9042);
      expect(line1[0].lon, 116.4074);

      // 面1：外环闭合（4 点输入 → 5 点输出，首尾相同）
      final ring = line
          .where((l) => l.lineGroupId != line.first.lineGroupId)
          .toList();
      expect(ring.length, 5);
      expect(ring.first.lat, ring.last.lat);
      expect(ring.first.lon, ring.last.lon);

      // 北京直属点：单层路径
      final bj = _unitOf(r, ['北京']);
      expect(bj.name, '北京');
      expect(bj.labels.single.name, '北京直属点');

      // 根点：路径为空、name 占位 ''
      final root = _unitOf(r, []);
      expect(root.name, '');
      expect(root.labels.single.name, '根点');

      expect(r.pointCount, 3);
      expect(r.labelCount, 1 + 2 + 5 + 1 + 1);

      // withFileName 补齐根级单元名，其他单元不动
      final renamed = r.withFileName('我的文件');
      expect(_unitOf(renamed, []).name, '我的文件');
      expect(_unitOf(renamed, ['北京', '朝阳']).name, '朝阳');
      expect(_unitOf(renamed, ['北京']).name, '北京');
    });

    test('无 OvCoordType 时缺省 WGS84', () {
      const kml =
          '<kml><Document><Placemark><name>p</name>'
          '<Point><coordinates>116.4,39.9</coordinates></Point>'
          '</Placemark></Document></kml>';
      final r = KmlParser.parse(kml);
      expect(r.detectedSystem, 'WGS84');
      expect(r.units.single.labels.single.lat, 39.9);
    });
  });

  group('KmzParser', () {
    List<int> buildKmz({required String kmlName, int pngCount = 0}) {
      final a = Archive();
      final kb = utf8.encode(_kmlSample);
      a.addFile(ArchiveFile(kmlName, kb.length, kb));
      for (var i = 0; i < pngCount; i++) {
        final pb = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, i];
        a.addFile(ArchiveFile('images/p$i.png', pb.length, pb));
      }
      return ZipEncoder().encode(a)!;
    }

    test('doc.kml + png 附件：解析正常、warnings 提示忽略图片', () {
      final r = KmzParser.parseBytes(
        buildKmz(kmlName: 'doc.kml', pngCount: 1),
        fileName: '测试.kmz',
      );
      expect(r.units.length, 3);
      expect(r.warnings, contains('已忽略 1 个图片附件'));
      expect(_unitOf(r, []).name, '测试'); // 根级单元名已补文件名
      expect(r.detectedSystem, 'GCJ02');
    });

    test('doc.kml 大小写不敏感', () {
      final r = KmzParser.parseBytes(buildKmz(kmlName: 'DOC.KML'));
      expect(r.units.length, 3);
    });

    test('缺失 doc.kml 抛 FormatException', () {
      final a = Archive();
      final pb = [0x89, 0x50, 0x4E, 0x47];
      a.addFile(ArchiveFile('a.png', pb.length, pb));
      final bytes = ZipEncoder().encode(a)!;
      expect(
        () => KmzParser.parseBytes(bytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('KMZ 内未找到 doc.kml'),
          ),
        ),
      );
    });
  });

  group('OvjsnParser', () {
    // BOM + Type 7/8/13 + Gcj02:1，第三个条目用条目级字段（无 Object 包裹）
    final json =
        '{\n'
        ' "ObjItems": [\n'
        '  {"Type": 7, "Object": {"Name": "点A", "Comment": "备注A",\n'
        '    "ObjectDetail": {"Lat": 32.1301, "Lng": 114.0814, "Gcj02": 1}}},\n'
        '  {"Type": 8, "Object": {"Name": "线B",\n'
        '    "ObjectDetail": {"Gcj02": 0, "PointList": [32.13, 114.08, 32.14, 114.09]}}},\n'
        '  {"Type": 13, "ObjName": "面C",\n'
        '    "ObjectDetail": {"PointList": [\n'
        '      {"Lat": 32.1, "Lng": 114.0},\n'
        '      {"Lat": 32.1, "Lng": 114.02},\n'
        '      {"Lat": 32.12, "Lng": 114.02}]}},\n'
        '  {"Type": 7, "Object": {"Name": "坏点",\n'
        '    "ObjectDetail": {"Lat": 999, "Lng": 999}}}\n'
        ' ]\n'
        '}';

    test('BOM + 点/线/面 + Gcj02 标志', () {
      final r = OvjsnParser.parse('$_bom$json', fileName: 'sample.ovjsn');

      expect(r.units.length, 1);
      final u = r.units.single;
      expect(u.name, 'sample');
      expect(u.folderPath, isEmpty);
      expect(u.description, '备注A');
      expect(r.detectedSystem, 'GCJ02');

      // 点A：Gcj02=1 → 转 WGS-84
      final pa = u.labels.firstWhere((l) => l.name == '点A');
      expect(pa.lat, closeTo(_wgsLatB, 1e-9));
      expect(pa.lon, closeTo(_wgsLonB, 1e-9));

      // 线B：扁平 PointList、Gcj02=0 原样
      final lineB = u.labels.where((l) => l.name == '线B').toList();
      expect(lineB.length, 1);
      final lg = u.labels
          .where(
            (l) =>
                l.lineGroupId.isNotEmpty &&
                l.lineGroupId == lineB.first.lineGroupId,
          )
          .toList();
      expect(lg.length, 2);
      expect(lg[0].lat, 32.13);
      expect(lg[1].lon, 114.09);

      // 面C：对象数组点串、闭合
      final ringGid = u.labels
          .firstWhere(
            (l) =>
                l.lineGroupId.isNotEmpty &&
                l.lineGroupId != lg.first.lineGroupId,
          )
          .lineGroupId;
      final ring = u.labels.where((l) => l.lineGroupId == ringGid).toList();
      expect(ring.length, 4); // 3 点输入 + 闭合点
      expect(ring.first.lat, ring.last.lat);
      expect(ring.first.lon, ring.last.lon);
      expect(ring.first.name, '面C');

      // 坏点（坐标越界）被跳过
      expect(u.labels.any((l) => l.name == '坏点'), isFalse);
      expect(r.labelCount, 1 + 2 + 4);
    });

    test('非法 JSON 抛 FormatException', () {
      expect(
        () => OvjsnParser.parse('{not json'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('OvobjParser', () {
    List<int> buildOvobj(List<(int, double, double, String)> objs) {
      final b = BytesBuilder();
      b.add([0x4F, 0x76, 0x69, 0x4F]); // 'OviO'
      final cnt = ByteData(4)..setUint32(0, objs.length, Endian.little);
      b.add(cnt.buffer.asUint8List());
      for (final o in objs) {
        b.add([o.$1]);
        if (o.$1 == 0x01) {
          final c = ByteData(16)
            ..setFloat64(0, o.$2, Endian.little)
            ..setFloat64(8, o.$3, Endian.little);
          b.add(c.buffer.asUint8List());
          final nb = utf8.encode(o.$4);
          final l = ByteData(2)..setUint16(0, nb.length, Endian.little);
          b.add(l.buffer.asUint8List());
          b.add(nb);
        }
      }
      return b.toBytes();
    }

    test('点对象：坐标/名称正确解析', () {
      final bytes = buildOvobj([
        (0x01, 32.1301, 114.0814, '杆1'),
        (0x01, 39.9042, 116.4074, '杆2'),
      ]);
      final r = OvobjParser.parseBytes(bytes, fileName: 'test.ovobj');
      expect(r.units.length, 1);
      final u = r.units.single;
      expect(u.name, 'test');
      expect(u.labels.length, 2);
      expect(u.labels[0].name, '杆1');
      expect(u.labels[0].lat, 32.1301);
      expect(u.labels[0].lon, 114.0814);
      expect(u.labels[1].name, '杆2');
      expect(r.detectedSystem, 'WGS84');
    });

    test('含线/面对象：拒绝整个导入', () {
      final bytes = buildOvobj([
        (0x01, 32.1301, 114.0814, '杆1'),
        (0x02, 0, 0, ''), // 线对象标记
      ]);
      expect(
        () => OvobjParser.parseBytes(bytes),
        throwsA(
          isA<OvobjUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('ovkml/ovkmz/ovjsn'),
          ),
        ),
      );
    });

    test('Magic 不符抛 FormatException', () {
      expect(
        () => OvobjParser.parseBytes([0x58, 0x58, 0x58, 0x58, 0, 0, 0, 0]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Magic 不符'),
          ),
        ),
      );
    });

    test('截断文件抛 FormatException', () {
      expect(
        () => OvobjParser.parseBytes([
          0x4F,
          0x76,
          0x69,
          0x4F,
          1,
          0,
          0,
          0,
          0x01,
          0,
        ]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Importer.parseFile 路由', () {
    test('扩展名分发（大小写不敏感）', () {
      final kmlBytes = utf8.encode(_kmlSample);
      for (final ext in ['kml', 'KML', 'ovkml', 'OvKml']) {
        final r = Importer.parseFile('a.$ext', kmlBytes);
        expect(r, isNotNull, reason: ext);
        expect(r!.units.length, 3);
        expect(_unitOf(r, []).name, 'a');
      }
      final ovjsnBytes = utf8.encode('{"ObjItems":[]}');
      expect(Importer.parseFile('b.OVJSN', ovjsnBytes), isNull); // 0 要素 → null

      final a = Archive();
      final kb = utf8.encode(_kmlSample);
      a.addFile(ArchiveFile('doc.kml', kb.length, kb));
      final kmz = ZipEncoder().encode(a)!;
      expect(Importer.parseFile('c.ovkmz', kmz)!.units.length, 3);
    });

    test('不支持的扩展名/无扩展名抛 FormatException', () {
      expect(
        () => Importer.parseFile('a.txt', [1, 2, 3]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('不支持的文件格式'),
          ),
        ),
      );
      expect(
        () => Importer.parseFile('abc', [1, 2, 3]),
        throwsA(isA<FormatException>()),
      );
    });

    test('0 要素返回 null', () {
      expect(Importer.parseFile('e.kml', utf8.encode('<kml></kml>')), isNull);
    });
  });
}
