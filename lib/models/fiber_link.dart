/// 光缆拓扑连线：人工指定的两设备之间的光缆连接。
///
/// 完全由人工控制，系统绝不自动生成、自动修改、自动挂载。
/// 一律以 JSON 落盘，与 MapLabel 同一工程文件。
class FiberLink {
  String id;
  String fromDeviceId;
  String toDeviceId;

  /// 芯数：6/12/24/48/96/144 或自定义。
  int cores;

  /// 光缆型号，如 "GYTS"、"GYTA"。
  String cableModel;

  /// 厂家。
  String manufacturer;

  /// 敷设方式：0=未填，1=架空，2=管道，3=直埋，4=引上。
  int layMethod;

  /// 光缆长度（米）。
  double lengthM;

  /// 熔接方式，如 "熔接"、"冷接"。
  String spliceMethod;

  /// 改造三态：0=原有，1=新增，2=拆除。纯加法，老数据默认为 0。
  int reno;

  /// 备注。
  String note;

  FiberLink({
    String? id,
    this.fromDeviceId = '',
    this.toDeviceId = '',
    this.cores = 0,
    this.cableModel = '',
    this.manufacturer = '',
    this.layMethod = 0,
    this.lengthM = 0,
    this.spliceMethod = '',
    this.reno = 0,
    this.note = '',
  }) : id = id ?? _uuid();

  static String _uuid() {
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'fl-$r';
  }

  /// 敷设方式名称。
  String get layMethodName {
    switch (layMethod) {
      case 1:
        return '架空';
      case 2:
        return '管道';
      case 3:
        return '直埋';
      case 4:
        return '引上';
      default:
        return '';
    }
  }

  /// 完整规格描述，如 "48芯GYTS（架空）"。
  String get fullSpec {
    final b = StringBuffer();
    if (cores > 0) b.write('${cores}芯');
    if (cableModel.isNotEmpty) b.write(cableModel);
    if (layMethodName.isNotEmpty) b.write('（$layMethodName）');
    return b.toString();
  }

  FiberLink clone() => FiberLink(
        id: id,
        fromDeviceId: fromDeviceId,
        toDeviceId: toDeviceId,
        cores: cores,
        cableModel: cableModel,
        manufacturer: manufacturer,
        layMethod: layMethod,
        lengthM: lengthM,
        spliceMethod: spliceMethod,
        reno: reno,
        note: note,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': fromDeviceId,
        'to': toDeviceId,
        'cores': cores,
        'model': cableModel,
        'mfr': manufacturer,
        'lay': layMethod,
        'len': lengthM,
        'splice': spliceMethod,
        if (reno != 0) 'reno': reno,
        'note': note,
      };

  factory FiberLink.fromJson(Map<String, dynamic> jo) => FiberLink(
        id: jo['id'] as String?,
        fromDeviceId: (jo['from'] as String?) ?? '',
        toDeviceId: (jo['to'] as String?) ?? '',
        cores: (jo['cores'] as num?)?.toInt() ?? 0,
        cableModel: (jo['model'] as String?) ?? '',
        manufacturer: (jo['mfr'] as String?) ?? '',
        layMethod: (jo['lay'] as num?)?.toInt() ?? 0,
        lengthM: (jo['len'] as num?)?.toDouble() ?? 0,
        spliceMethod: (jo['splice'] as String?) ?? '',
        reno: (jo['reno'] as num?)?.toInt() ?? 0,
        note: (jo['note'] as String?) ?? '',
      );
}

/// 常用光缆芯数选项。
const List<int> kCommonFiberCores = [6, 12, 24, 48, 96, 144];

/// 敷设方式选项（0=未填，1=架空，2=管道，3=直埋，4=引上）。
const Map<int, String> kLayMethods = {
  1: '架空',
  2: '管道',
  3: '直埋',
  4: '引上',
};
