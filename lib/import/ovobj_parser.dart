import 'dart:convert';
import 'dart:typed_data';

import '../models/map_label.dart';
import 'import_model.dart';

/// ovobj 私有二进制中出现线/面对象时抛出：拒绝整个导入，绝不静默丢数据。
class OvobjUnsupportedException implements Exception {
  final String message;
  const OvobjUnsupportedException(this.message);
  @override
  String toString() => 'OvobjUnsupportedException: $message';
}

/// 奥维私有二进制（.ovobj）解析。
///
/// 二进制布局依据社区逆向项目结论（fangster-1/ovkml-converter，非官方），
/// **仅点对象可被可靠解析**：
/// ```
/// 'OviO'                  4 字节 ASCII Magic
/// u32 LE                  对象总数
/// 每对象:
///   u8                    类型: 0x01=点；其他=线/面等（见下）
///   f64 LE                纬度（仅点）
///   f64 LE                经度（仅点）
///   u16 LE                名称字节数（仅点）
///   UTF-8                 名称（仅点）
/// ```
/// 线/面对象采用私有压缩编码，无法可靠解析：一旦检测到非点对象，
/// 抛出 [OvobjUnsupportedException] 拒绝整个导入（不静默丢数据）。
/// 建议用户在奥维中改导 ovkml/ovkmz/ovjsn 后再导入。
///
/// 点坐标按 WGS-84 直接采用（社区逆向结论；如后续发现是 GCJ-02 需加标志位处理）。
/// 纯静态、无 UI 依赖；大文件时由 UI 层经 `Isolate.run` 调用。
class OvobjParser {
  OvobjParser._();

  static const _typePoint = 0x01;

  static ImportParseResult parseBytes(List<int> bytes, {String fileName = ''}) {
    if (bytes.length < 8) {
      throw FormatException('不是有效的 ovobj 文件（文件过短）');
    }
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic != 'OviO') {
      throw FormatException('不是有效的 ovobj 文件（Magic 不符）');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final count = data.getUint32(4, Endian.little);
    var off = 8;

    final labels = <MapLabel>[];
    final warnings = <String>[];
    for (var i = 0; i < count; i++) {
      if (off + 1 > bytes.length) {
        throw FormatException('ovobj 文件截断：对象 #$i 类型字节缺失');
      }
      final type = data.getUint8(off);
      off += 1;
      if (type != _typePoint) {
        // 线/面（或未知）对象：私有压缩编码无法可靠解析，拒绝整个导入
        throw const OvobjUnsupportedException(
          '文件中含线/面对象，ovobj 私有压缩编码无法可靠解析，'
          '请在奥维中改导 ovkml/ovkmz/ovjsn 后再导入',
        );
      }
      if (off + 16 > bytes.length) {
        throw FormatException('ovobj 文件截断：对象 #$i 坐标缺失');
      }
      final lat = data.getFloat64(off, Endian.little);
      off += 8;
      final lon = data.getFloat64(off, Endian.little);
      off += 8;
      if (off + 2 > bytes.length) {
        throw FormatException('ovobj 文件截断：对象 #$i 名称长度缺失');
      }
      final nameLen = data.getUint16(off, Endian.little);
      off += 2;
      if (off + nameLen > bytes.length) {
        throw FormatException('ovobj 文件截断：对象 #$i 名称越界');
      }
      final name = utf8.decode(
        bytes.sublist(off, off + nameLen),
        allowMalformed: true,
      );
      off += nameLen;

      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
        warnings.add('已跳过 1 个坐标越界的点（$name）');
        continue;
      }
      labels.add(MapLabel(typeId: 'pipe', lat: lat, lon: lon, name: name));
    }
    if (off < bytes.length) {
      warnings.add('文件尾部有多余 ${bytes.length - off} 字节，已忽略');
    }

    for (var i = 0; i < labels.length; i++) {
      labels[i].seq = i + 1;
    }
    final units = labels.isEmpty
        ? <ImportUnit>[]
        : [
            ImportUnit(
              folderPath: const [],
              name: baseNameWithoutExt(fileName),
              labels: labels,
            ),
          ];
    return ImportParseResult(units: units, warnings: warnings);
  }
}
