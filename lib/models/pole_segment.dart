/// 杆路段：独立命名、独立台账、独立编辑的杆路分段。
///
/// 支持无限续画：保存后任意点位可新建多条独立杆路，
/// 同一杆路不同段落可单独设置材质、敷设方式、建设年代。
class PoleSegment {
  String id;

  /// 分段名称，如 "杆路A-1段"。
  String name;

  /// 点位 ID 链（按顺序）。
  List<String> pointIds;

  /// 材质，如 "水泥杆"、"钢管杆"。
  String material;

  /// 敷设方式：0=未填，1=架空，2=管道，3=直埋。
  int layMethod;

  /// 建设年代，如 "2024"。
  String buildYear;

  /// 备注。
  String note;

  PoleSegment({
    String? id,
    this.name = '',
    List<String>? pointIds,
    this.material = '',
    this.layMethod = 0,
    this.buildYear = '',
    this.note = '',
  })  : id = id ?? _uuid(),
        pointIds = pointIds ?? [];

  static String _uuid() {
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'ps-$r';
  }

  PoleSegment clone() => PoleSegment(
        id: id,
        name: name,
        pointIds: List<String>.from(pointIds),
        material: material,
        layMethod: layMethod,
        buildYear: buildYear,
        note: note,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'points': pointIds,
        'material': material,
        'lay': layMethod,
        'year': buildYear,
        'note': note,
      };

  factory PoleSegment.fromJson(Map<String, dynamic> jo) => PoleSegment(
        id: jo['id'] as String?,
        name: (jo['name'] as String?) ?? '',
        pointIds: (jo['points'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            [],
        material: (jo['material'] as String?) ?? '',
        layMethod: (jo['lay'] as num?)?.toInt() ?? 0,
        buildYear: (jo['year'] as String?) ?? '',
        note: (jo['note'] as String?) ?? '',
      );
}
