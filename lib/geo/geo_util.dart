import 'dart:math' as math;

/// 几何与格式化工具：距离/面积/比例尺/坐标格式化。
class GeoUtil {
  GeoUtil._();

  static const int tile = 256;
  static const double earthR = 6371000.0;

  /// 坐标格式：0=十进制度 1=度分秒 2=度.分
  static const int fmtDec = 0;
  static const int fmtDms = 1;
  static const int fmtDm = 2;

  /// 大圆距离（米）。
  static double haversine(double la1, double lo1, double la2, double lo2) {
    final dLat = _rad(la2 - la1);
    final dLon = _rad(lo2 - lo1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(la1)) * math.cos(_rad(la2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return earthR * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// 球面多边形面积（平方米，取绝对值）。
  static double polygonArea(List<double> lats, List<double> lons, int count) {
    if (count < 3) return 0;
    var total = 0.0;
    for (var i = 0; i < count; i++) {
      final j = (i + 1) % count;
      final lon1 = _rad(lons[i]);
      final lon2 = _rad(lons[j]);
      final lat1 = _rad(lats[i]);
      final lat2 = _rad(lats[j]);
      total += (lon2 - lon1) * (2 + math.sin(lat1) + math.sin(lat2));
    }
    return (total * earthR * earthR / 2.0).abs();
  }

  /// 某纬度处每像素对应的地面距离（米），z 为连续浮点级别。
  static double metersPerPixel(double lat, double z) {
    return 2 * math.pi * earthR * math.cos(_rad(lat)) /
        (tile * math.pow(2, z));
  }

  /// 把米数格式化为 <1km 显示 m，否则 km 保留两位。
  static String fmtDist(double m) {
    if (m.isNaN) return '-';
    if (m < 1000) return '${m.toStringAsFixed(0)}米';
    return '${(m / 1000).toStringAsFixed(2)}公里';
  }

  /// 线段上的距离标签：米保留一位小数；>999 显示公里两位。
  static String fmtSegLen(double m) {
    if (m < 1000) return m.toStringAsFixed(1);
    return '${(m / 1000).toStringAsFixed(2)}km';
  }

  /// 面积显示：平方米/公顷/平方公里自动切换，附亩。
  static String fmtArea(double sqm) {
    final sb = StringBuffer();
    if (sqm < 10000) {
      sb.write('${sqm.toStringAsFixed(0)} ㎡');
    } else if (sqm < 1000000) {
      sb.write('${(sqm / 10000).toStringAsFixed(2)} 公顷');
    } else {
      sb.write('${(sqm / 1000000).toStringAsFixed(2)} 平方公里');
    }
    sb.write('（${(sqm / 666.6667).toStringAsFixed(2)}亩）');
    return sb.toString();
  }

  static String fmtScaleLabel(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(0)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  /// 坐标格式化。
  static String formatCoord(double lat, double lon, int fmt) =>
      '${formatLat(lat, fmt)}, ${formatLon(lon, fmt)}';

  static String formatLat(double lat, int fmt) =>
      '${lat >= 0 ? 'N' : 'S'} ${_formatAngle(lat.abs(), fmt)}';

  static String formatLon(double lon, int fmt) =>
      '${lon >= 0 ? 'E' : 'W'} ${_formatAngle(lon.abs(), fmt)}';

  static String _formatAngle(double deg, int fmt) {
    if (fmt == fmtDec) return '${deg.toStringAsFixed(6)}°';
    final d = deg.floor();
    final rem = (deg - d) * 60;
    if (fmt == fmtDm) return "$d°${rem.toStringAsFixed(6)}′";
    final m = rem.floor();
    final s = (rem - m) * 60;
    return "$d°$m′${s.toStringAsFixed(2)}″";
  }

  static String fmtName(int fmt) {
    switch (fmt) {
      case fmtDms:
        return '度分秒';
      case fmtDm:
        return '度.分';
      default:
        return '十进制';
    }
  }

  /// 解析用户输入的坐标：
  /// · 十进制："114.08,32.13" / "32.13 114.08" / "32.13°,114.08°"
  /// · 度分秒："32°07'48"N 114°05'24"E"（°/度、′/分、″/秒 混排均可）
  /// 返回 [lat, lon]，解析失败返回 null。
  static List<double>? parseCoordInput(String? text) {
    if (text == null) return null;
    var s = text.trim()
        .replaceAll('，', ',')
        .replaceAll('、', ',')
        .replaceAll(';', ',')
        .replaceAll('；', ',');
    if (s.isEmpty) return null;

    // 度分秒：输入里带 ° 且能抽出两组"度分秒"
    if (s.contains('°') || s.contains('度')) {
      final dms = parseDmsInput(s);
      if (dms != null) return dms;
    }

    List<String> parts;
    if (s.contains(',')) {
      parts = s.split(RegExp(r'\s*,\s*'));
    } else {
      parts = s.split(RegExp(r'\s+'));
    }
    if (parts.length != 2) return null;
    final a = double.tryParse(parts[0].replaceAll('°', ''));
    final b = double.tryParse(parts[1].replaceAll('°', ''));
    if (a == null || b == null) return null;
    var lat = a, lon = b;
    if (lat.abs() > 90 && lon.abs() <= 90) {
      final t = lat;
      lat = lon;
      lon = t;
    }
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return [lat, lon];
  }

  /// 度分秒解析："32°07'48"N 114°05'24"E"。
  /// 半球字母（N/S/E/W）优先判定经纬；无字母时按"先纬后经"惯例。
  static List<double>? parseDmsInput(String s) {
    final re = RegExp(
        r'''([NSEW])?\s*(\d{1,3})(?:[°度]\s*(\d{1,2}(?:\.\d+)?)[′分']?\s*(?:(\d{1,2}(?:\.\d+)?)[″秒"]?)?)?\s*([NSEW])?''',
        caseSensitive: false);
    final ms = re.allMatches(s).where((m) => m.group(2) != null).toList();
    if (ms.length != 2) return null;
    double val(Match m) {
      final d = double.parse(m.group(2)!);
      final mi = double.tryParse(m.group(3) ?? '') ?? 0;
      final sec = double.tryParse(m.group(4) ?? '') ?? 0;
      return d + mi / 60 + sec / 3600;
    }

    String? hemi(Match m) =>
        (m.group(1) ?? m.group(5))?.toUpperCase();
    final v1 = val(ms[0]), v2 = val(ms[1]);
    final h1 = hemi(ms[0]), h2 = hemi(ms[1]);
    var lat = v1, lon = v2;
    if (h1 == 'E' || h1 == 'W' || h2 == 'N' || h2 == 'S') {
      lon = v1;
      lat = v2;
    }
    if (h1 == 'S' || h2 == 'S') lat = -lat;
    if (h1 == 'W' || h2 == 'W') lon = -lon;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return [lat, lon];
  }

  /// 米/秒 -> 公里/时。
  static String fmtSpeed(double mps) =>
      '${(mps * 3.6).toStringAsFixed(1)} km/h';

  static double _rad(double deg) => deg * math.pi / 180.0;
}
