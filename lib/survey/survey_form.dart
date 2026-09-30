import '../models/map_label.dart';

/// 勘察表单（Phase 5）：杆位/箱体现场勘察记录。
///
/// 落盘位置为 `MapLabel.extra['survey']`——与 extra 里的其他键互不覆盖，
/// 老工程无此键时表单为 null（页面打开即新建）。
class SurveyForm {
  /// 勘察人。
  String surveyor;

  /// 杆型（如"8米水泥杆"），自由文本。
  String poleType;

  /// 杆高（米），未填为 null。
  double? poleHeight;

  /// 周边环境描述。
  String envDesc;

  /// 是否可立杆。
  bool canErect;

  /// 敷设建议。
  String advice;

  /// 勘察时间：新建表单时自动记为当前时间。
  DateTime surveyedAt;

  /// 勘察照片相对路径列表（存于 `photos/survey/<cid>/<labelId>/` 下，
  /// 相对路径形如 `survey/<cid>/<labelId>/<文件名>`）。
  List<String> photos;

  SurveyForm({
    this.surveyor = '',
    this.poleType = '',
    this.poleHeight,
    this.envDesc = '',
    this.canErect = true,
    this.advice = '',
    DateTime? surveyedAt,
    List<String>? photos,
  })  : surveyedAt = surveyedAt ?? DateTime.now(),
        photos = photos ?? [];

  /// 从 [MapLabel] 的 `extra['survey']` 读出表单；无数据返回 null。
  static SurveyForm? fromLabel(MapLabel l) {
    final m = l.extra?['survey'];
    if (m is Map) {
      return SurveyForm.fromJson(
          m.map((k, v) => MapEntry(k.toString(), v)));
    }
    return null;
  }

  /// 把表单写回 [MapLabel] 的 `extra['survey']`，
  /// extra 里其他键原样保留、互不覆盖。
  void applyTo(MapLabel l) {
    final extra = Map<String, dynamic>.from(l.extra ?? {});
    extra['survey'] = toJson();
    l.extra = extra;
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'surveyor': surveyor,
      'poleType': poleType,
      'envDesc': envDesc,
      'canErect': canErect,
      'advice': advice,
      'surveyedAt': surveyedAt.toIso8601String(),
    };
    if (poleHeight != null) m['poleHeight'] = poleHeight;
    if (photos.isNotEmpty) m['photos'] = photos;
    return m;
  }

  factory SurveyForm.fromJson(Map<String, dynamic> jo) {
    DateTime at;
    try {
      at = DateTime.parse((jo['surveyedAt'] as String?) ?? '');
    } catch (_) {
      at = DateTime.now();
    }
    return SurveyForm(
      surveyor: (jo['surveyor'] as String?) ?? '',
      poleType: (jo['poleType'] as String?) ?? '',
      poleHeight: (jo['poleHeight'] as num?)?.toDouble(),
      envDesc: (jo['envDesc'] as String?) ?? '',
      canErect: (jo['canErect'] as bool?) ?? true,
      advice: (jo['advice'] as String?) ?? '',
      surveyedAt: at,
      photos:
          (jo['photos'] as List?)?.map((e) => e.toString()).toList(),
    );
  }

  SurveyForm clone() => SurveyForm(
        surveyor: surveyor,
        poleType: poleType,
        poleHeight: poleHeight,
        envDesc: envDesc,
        canErect: canErect,
        advice: advice,
        surveyedAt: surveyedAt,
        photos: List<String>.from(photos),
      );
}
