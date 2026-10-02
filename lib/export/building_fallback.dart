/// 建筑兜底包：本地预置建筑轮廓数据（CMAB 等开源数据集预处理）。
///
/// 背景：中国区 OSM `building=*` 覆盖稀疏，Overpass 经常抓回空集。
/// 兜底包是按城市预处理好的建筑 GeoJSON（WGS84），`BasemapFetcher.fetchFor`
/// 在 OSM 建筑为空/过少时自动按 bbox 查询补上。
///
/// 目录：`${basemapDir}/fallback/`（与 `buildings/` 缓存同级）：
/// - `index.json`：已安装包元数据 `{id, name, version(int), source, date, buildings}`
/// - `<id>.geojson`：该包建筑（FeatureCollection，Polygon/MultiPolygon，WGS84）
///
/// ## 后台更新
///
/// 注册表指向的是各包的 `manifest.json`（几 KB），而非数据文件本身。
/// App 启动后延迟几秒在后台拉 manifest，比对 `version`：
/// 已安装且远端版本更新 → 自动下载替换（原子写入），用户无需手动重下。
/// 导出面板也提供"检查更新"手动触发。所有后台路径永不抛异常。
///
/// 包由维护方离线预处理（shapefile → WGS84 → 按市裁剪 → GeoJSON），
/// 发新版时只需更新数据分支上的 `manifest.json`（version+1，指向新文件）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../services/store.dart';
import 'basemap.dart';

/// 可下载的兜底包注册表项：只记 manifest 地址（多个镜像按顺序尝试），
/// 具体版本/下载地址以 manifest 为准（后台更新的比对依据）。
class FallbackPackage {
  final String id;
  final String name;

  /// manifest 镜像地址（按顺序尝试；国内优先 jsDelivr CDN）。
  final List<String> manifestUrls;
  final String source;
  const FallbackPackage({
    required this.id,
    required this.name,
    required this.manifestUrls,
    required this.source,
  });
}

/// manifest.json 解析结果（远端最新发布）。
class FallbackRelease {
  final String id;
  final String name;
  final int version;

  /// 数据文件镜像地址（按顺序尝试；`url` 为主，`mirrors` 为备）。
  final List<String> urls;
  final int bytes;
  final int buildings;
  final String source;
  final String updated;
  const FallbackRelease({
    required this.id,
    required this.name,
    required this.version,
    required this.urls,
    required this.bytes,
    required this.buildings,
    required this.source,
    required this.updated,
  });

  static FallbackRelease? parse(Map<String, dynamic> json) {
    try {
      final v = json['version'];
      final version = v is int ? v : int.tryParse('$v') ?? 0;
      final urls = <String>[];
      final rawPrimary = json['url'];
      if (rawPrimary is String && rawPrimary.isNotEmpty) {
        urls.add(rawPrimary);
      }
      final mirrors = json['mirrors'];
      if (mirrors is List) {
        for (final m in mirrors) {
          if (m is String && m.isNotEmpty && !urls.contains(m)) urls.add(m);
        }
      }
      if (version <= 0 || urls.isEmpty) return null;
      return FallbackRelease(
        id: '${json['id']}',
        name: '${json['name']}',
        version: version,
        urls: urls,
        bytes: (json['bytes'] as num?)?.toInt() ?? -1,
        buildings: (json['buildings'] as num?)?.toInt() ?? 0,
        source: '${json['source'] ?? ''}',
        updated: '${json['updated'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 检查到的可用更新。
class FallbackUpdate {
  final FallbackPackage pkg;
  final FallbackRelease release;
  final int fromVersion;
  const FallbackUpdate(this.pkg, this.release, this.fromVersion);
}

/// 单测注入 HTTP（返回 `statusCode` + 完整 body）；为 null 时走真实网络。
typedef FallbackHttpGet = Future<({int statusCode, List<int> body})>
    Function(Uri url);

/// 当前已发布的兜底包（v1：信阳市，CMAB v7 预处理）。
///
/// manifest 走多镜像：jsDelivr（国内 CDN）优先，raw.githubusercontent 备用。
List<FallbackPackage> get fallbackRegistry => const [
      FallbackPackage(
        id: 'xinyang',
        name: '信阳市',
        manifestUrls: [
          'https://cdn.jsdelivr.net/gh/dujianhua200/ovimap'
              '@data/buildings-xinyang-v1/manifest.json',
          'https://raw.githubusercontent.com/dujianhua200/ovimap/'
              'data/buildings-xinyang-v1/manifest.json',
        ],
        source: 'CMAB v7（2025-04-20，清华大学）预处理',
      ),
    ];

class FallbackStore {
  final Directory root;
  FallbackStore(this.root);

  static FallbackHttpGet? httpGetOverride;

  static Future<FallbackStore> open() async {
    final base = await LabelStore.instance.basemapDir();
    final d = Directory('${base.path}/fallback');
    if (!d.existsSync()) d.createSync(recursive: true);
    return FallbackStore(d);
  }

  File get _indexFile => File('${root.path}/index.json');

  /// 已安装包元数据（未安装返回 null）。`version` 统一为 int；
  /// 兼容旧版写下的字符串 `'v1'`。
  Map<String, dynamic>? meta([String id = 'xinyang']) {
    try {
      final f = _indexFile;
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map) {
        final m = Map<String, dynamic>.from(decoded);
        if (m['id'] != id) return null;
        m['version'] = _asVersion(m['version']);
        return m;
      }
    } catch (_) {}
    return null;
  }

  static int _asVersion(dynamic v) {
    if (v is int) return v;
    final s = '$v'.replaceAll(RegExp(r'[^0-9]'), '');
    return int.tryParse(s) ?? 0;
  }

  bool get hasPackage => meta() != null;

  File _pkgFile(String id) => File('${root.path}/$id.geojson');

  /// GET 下载。manifest 等小文件直接返回 body；大数据走 [onChunk] 流式
  /// 回调（收 `(chunk, received, total)`），避免 18MB 级文件常驻内存。
  Future<({int statusCode, List<int> body})> _get(
    Uri url, {
    void Function(List<int> chunk, int received, int total)? onChunk,
  }) async {
    final ov = httpGetOverride;
    if (ov != null) {
      final r = await ov(url);
      if (onChunk != null && r.body.isNotEmpty) {
        onChunk(r.body, r.body.length, r.body.length);
      }
      return r;
    }
    final req = await HttpClient().getUrl(url);
    final resp = await req.close();
    final total = resp.contentLength;
    final buf = <int>[];
    var received = 0;
    await for (final chunk in resp) {
      received += chunk.length;
      if (onChunk != null) {
        onChunk(chunk, received, total);
      } else {
        buf.addAll(chunk);
      }
    }
    return (statusCode: resp.statusCode, body: buf);
  }

  /// 拉取远端 manifest（按镜像顺序尝试，全部失败返回 null，不抛异常）。
  ///
  /// 后台更新用；前台手动下载请用 [fetchReleaseOrThrow] 以便展示失败原因。
  Future<FallbackRelease?> fetchRelease(FallbackPackage pkg) async {
    try {
      return await fetchReleaseOrThrow(pkg);
    } catch (_) {
      return null;
    }
  }

  /// 拉取远端 manifest；全部镜像失败时抛带各镜像错误详情的异常。
  Future<FallbackRelease> fetchReleaseOrThrow(FallbackPackage pkg) async {
    final errors = <String>[];
    for (final murl in pkg.manifestUrls) {
      final host = Uri.parse(murl).host;
      try {
        final r = await _get(Uri.parse(murl))
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) {
          errors.add('$host: HTTP ${r.statusCode}');
          continue;
        }
        final decoded = jsonDecode(utf8.decode(r.body));
        if (decoded is! Map) {
          errors.add('$host: manifest 格式错误');
          continue;
        }
        final rel = FallbackRelease.parse(Map<String, dynamic>.from(decoded));
        if (rel != null) return rel;
        errors.add('$host: manifest 版本无效');
      } catch (e) {
        errors.add('$host: ${_shortErr(e)}');
      }
    }
    throw HttpException('获取版本信息失败（${errors.join('；')}），请检查网络后重试');
  }

  /// 把异常压成一行，避免堆栈刷屏。
  static String _shortErr(Object e) {
    final s = '$e';
    final i = s.indexOf('\n');
    final first = (i < 0 ? s : s.substring(0, i)).trim();
    // 去掉 "HttpException: " 等前缀噪音，保留关键信息
    return first.length > 160 ? '${first.substring(0, 160)}…' : first;
  }

  /// 检查已安装包的可用更新（未安装/无更新/网络失败 → 空列表，不抛异常）。
  Future<List<FallbackUpdate>> checkForUpdates() async {
    final out = <FallbackUpdate>[];
    for (final pkg in fallbackRegistry) {
      final m = meta(pkg.id);
      if (m == null) continue;
      final rel = await fetchRelease(pkg);
      if (rel == null) continue;
      final local = _asVersion(m['version']);
      if (rel.version > local) out.add(FallbackUpdate(pkg, rel, local));
    }
    return out;
  }

  /// 按 bbox（`[minLat, minLon, maxLat, maxLon]`）查询兜底包建筑。
  ///
  /// GeoJSON 可能很大：流式只取外环与 bbox 相交的要素（整文件读入、
  /// 逐 feature 判断，不做全量几何运算）。
  Future<List<BuildingPoly>> query(List<double> bbox,
      {String id = 'xinyang'}) async {
    final f = _pkgFile(id);
    if (!f.existsSync()) return [];
    final minLat = bbox[0], minLon = bbox[1], maxLat = bbox[2], maxLon = bbox[3];
    final out = <BuildingPoly>[];
    try {
      final text = await f.readAsString();
      final root = jsonDecode(text);
      final feats = root is Map ? root['features'] : null;
      if (feats is! List) return [];
      for (final feat in feats) {
        if (feat is! Map) continue;
        final geom = feat['geometry'];
        if (geom is! Map) continue;
        final type = geom['type'];
        final coords = geom['coords'] ?? geom['coordinates'];
        if (coords is! List) continue;
        final polys = type == 'Polygon'
            ? [coords]
            : type == 'MultiPolygon'
                ? coords
                : null;
        if (polys == null) continue;
        for (final poly in polys) {
          if (poly is! List || poly.isEmpty) continue;
          final rings = <List<List<double>>>[];
          var hit = false;
          for (final ring in poly) {
            if (ring is! List) continue;
            final pts = <List<double>>[];
            for (final p in ring) {
              if (p is! List || p.length < 2) continue;
              final lon = (p[0] as num).toDouble();
              final lat = (p[1] as num).toDouble();
              pts.add([lat, lon]); // BuildingPoly 点序为 [lat, lon]
              if (!hit &&
                  lat >= minLat &&
                  lat <= maxLat &&
                  lon >= minLon &&
                  lon <= maxLon) {
                hit = true;
              }
            }
            if (pts.isNotEmpty) rings.add(pts);
          }
          if (hit && rings.isNotEmpty) {
            out.add(BuildingPoly(rings, ''));
          }
        }
      }
    } catch (_) {
      return [];
    }
    return out;
  }

  /// 下载并安装兜底包；[onProgress] 收 `(received, total)`（total 可能为 -1）。
  ///
  /// 先拉 manifest 拿真实下载地址与版本号；URL 以 `.gz` 结尾时自动解压。
  /// 数据文件按 manifest 镜像顺序尝试（国内优先走 CDN）。
  Future<void> install(
    FallbackPackage pkg, {
    void Function(int received, int total)? onProgress,
    void Function(String stage)? onStage,
  }) async {
    onStage?.call('正在获取版本信息…');
    final rel = await fetchReleaseOrThrow(pkg);
    await _installRelease(pkg, rel,
        onProgress: onProgress, onStage: onStage);
  }

  /// 安装指定版本（后台更新用）；原子替换，失败不破坏旧包。
  Future<void> update(
    FallbackPackage pkg,
    FallbackRelease rel, {
    void Function(int received, int total)? onProgress,
    void Function(String stage)? onStage,
  }) =>
      _installRelease(pkg, rel, onProgress: onProgress, onStage: onStage);

  Future<void> _installRelease(
    FallbackPackage pkg,
    FallbackRelease rel, {
    void Function(int received, int total)? onProgress,
    void Function(String stage)? onStage,
  }) async {
    final errors = <String>[];
    for (var i = 0; i < rel.urls.length; i++) {
      final url = Uri.parse(rel.urls[i]);
      if (i > 0) onStage?.call('主线路不通，切换备用线路…');
      try {
        await _downloadOne(pkg, rel, url, onProgress: onProgress);
        return;
      } catch (e) {
        errors.add('${url.host}: ${_shortErr(e)}');
        // 换下一个镜像
      }
    }
    throw HttpException('下载失败（${errors.join('；')}）');
  }

  Future<void> _downloadOne(
    FallbackPackage pkg,
    FallbackRelease rel,
    Uri url, {
    void Function(int received, int total)? onProgress,
  }) async {
    final tmp = File('${root.path}/${pkg.id}.geojson.tmp');
    final sink = tmp.openWrite();
    var sinkOpen = true;
    Future<void> closeSink() async {
      if (sinkOpen) {
        sinkOpen = false;
        await sink.close();
      }
    }

    try {
      final r = await _get(
        url,
        onChunk: (chunk, rx, t) {
          sink.add(chunk);
          onProgress?.call(rx, t);
        },
      ).timeout(const Duration(minutes: 5));
      await closeSink();
      if (r.statusCode != 200) {
        throw HttpException('下载失败：HTTP ${r.statusCode}', uri: url);
      }
    } catch (e) {
      await closeSink();
      if (tmp.existsSync()) await tmp.delete();
      rethrow;
    }
    // gzip 解压（发布包为 .gz 以省流量）。
    String text;
    final isGz = url.path.endsWith('.gz');
    try {
      final raw = await tmp.readAsBytes();
      text = isGz ? utf8.decode(gzip.decode(raw)) : utf8.decode(raw);
    } catch (e) {
      await tmp.delete();
      throw FormatException('建筑包解压失败：$e');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['type'] != 'FeatureCollection') {
      await tmp.delete();
      throw const FormatException('下载的文件不是合法建筑包（GeoJSON）');
    }
    final feats = decoded['features'];
    final count = feats is List ? feats.length : 0;
    // 原子替换：解压后的文本落盘（而非 .gz 原始字节），验证通过再 rename，
    // 失败旧包不受影响。
    await tmp.writeAsString(text);
    await tmp.rename(_pkgFile(pkg.id).path);
    _indexFile.writeAsStringSync(jsonEncode({
      'id': pkg.id,
      'name': rel.name.isNotEmpty ? rel.name : pkg.name,
      'version': rel.version,
      'source': rel.source.isNotEmpty ? rel.source : pkg.source,
      'date': DateTime.now().toIso8601String().substring(0, 10),
      'updated': rel.updated,
      'buildings': count,
    }));
  }

  /// 后台更新入口：检查已安装包，有新版则自动下载替换。
  ///
  /// 返回成功更新的包数；**永不抛异常**（后台任务不得影响主流程）。
  /// [onProgress] 仅用于前台手动"检查更新"时展示进度。
  Future<int> ensureLatest({
    void Function(String id, int received, int total)? onProgress,
  }) async {
    try {
      final updates = await checkForUpdates();
      var done = 0;
      for (final u in updates) {
        try {
          await update(u.pkg, u.release,
              onProgress: onProgress == null
                  ? null
                  : (rx, total) => onProgress(u.pkg.id, rx, total));
          done++;
        } catch (_) {
          // 单个包更新失败不影响其他包
        }
      }
      return done;
    } catch (_) {
      return 0;
    }
  }

  /// 删除已安装包。
  Future<void> uninstall([String id = 'xinyang']) async {
    final f = _pkgFile(id);
    if (f.existsSync()) await f.delete();
    if (_indexFile.existsSync()) await _indexFile.delete();
  }
}

/// App 启动后调用的后台更新（延迟几秒、抓获所有异常、不阻塞启动）。
Future<int> checkFallbackUpdatesInBackground() async {
  try {
    final store = await FallbackStore.open();
    return await store.ensureLatest();
  } catch (_) {
    return 0;
  }
}
