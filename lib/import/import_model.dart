import '../geo/gcj02.dart';
import '../models/map_label.dart';

/// 导入要素归属的文件夹路径（KML `<Folder>` 嵌套层级）。
/// 空列表 = 根级要素（不建顶层文件夹，直接建工程）。
typedef FolderPath = List<String>;

/// 单个导入单元：同一文件夹路径下的要素集合 → 收藏树里的一个工程。
class ImportUnit {
  /// 文件夹路径，如 ['北京', '朝阳']；[] 表示根级。
  final FolderPath folderPath;

  /// 工程名：Folder 名；根级时为文件名去扩展名。
  final String name;

  /// 该单元的标签（点 / 线链，lineGroupId 已就地保留）。
  final List<MapLabel> labels;

  /// `<description>` / 备注（可空）。
  final String? description;

  const ImportUnit({
    required this.folderPath,
    required this.name,
    required this.labels,
    this.description,
  });
}

/// 解析结果：全部输出坐标已统一为 WGS-84（App 内部标准）。
class ImportParseResult {
  final List<ImportUnit> units;

  /// 检出的源坐标系：'WGS84' | 'GCJ02' | 'CGCS2000'（后者视为等同 WGS84）。
  final String detectedSystem;

  /// 非致命提示（如"已忽略 N 个图片附件"），UI 层 toast 展示。
  final List<String> warnings;

  const ImportParseResult({
    required this.units,
    this.detectedSystem = 'WGS84',
    this.warnings = const [],
  });

  int get pointCount => units.fold(
    0,
    (n, u) =>
        n +
        u.labels.where((l) => l.lineGroupId.isEmpty).length,
  );

  int get labelCount => units.fold(0, (n, u) => n + u.labels.length);

  bool get isEmpty => units.isEmpty || labelCount == 0;

  /// 返回新结果：根级（folderPath 为空）单元的名字补为 [name]，其余单元不动。
  /// 解析器对根级单元名用 '' 占位，由调用方（知道文件名的一侧）补齐。
  ImportParseResult withFileName(String name) {
    if (name.isEmpty) return this;
    return ImportParseResult(
      units: [
        for (final u in units)
          u.folderPath.isEmpty
              ? ImportUnit(
                  folderPath: u.folderPath,
                  name: name,
                  labels: u.labels,
                  description: u.description,
                )
              : u,
      ],
      detectedSystem: detectedSystem,
      warnings: warnings,
    );
  }
}

/// GCJ-02 → WGS-84；中国境外原样返回。
/// 返回 [lat, lon]。
List<double> importToWgs84(double lat, double lon, {required bool isGcj02}) {
  if (!isGcj02) return [lat, lon];
  if (Gcj02Converter.outOfChina(lat, lon)) return [lat, lon];
  return Gcj02Converter.gcj02ToWgs84(lat, lon);
}

/// 文件名去扩展名（'abc.ovkml' → 'abc'）。
String baseNameWithoutExt(String fileName) {
  final base = fileName.split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}
