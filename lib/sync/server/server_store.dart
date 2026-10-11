/// 同步服务端磁盘存储（Windows 内嵌服务）。
///
/// 布局（设计稿 §2.4，`AppPaths.syncServerDir()` 下 `ovimap-sync/`）：
/// ```
/// <root>/
///   accounts.json                       # [{id, name, createdAt}]（不含密钥）
///   <accountId>/
///     devices.json                      # 配对过的设备 [{deviceId, deviceName, pairedAt}]
///     2026-10-11/                       # 按天归档
///       <cid>.r<rev>.json               # 工程快照（每 rev 独立文件，含 rev/updatedAt/meta/payload）
///       <cid>.conflict-<deviceId>-<ts>.json  # 冲突快照（"留双份"）
///       <cid>.photos/
///         <sha256>.jpg
/// ```
///
/// - `PUT` 落**当天**日期目录；`GET /index` 合并该账号所有日期目录，去重取最大 rev。
/// - 密钥绝不落盘：token 读写经注入的 [TokenStore]（Worker C 的 secure_store 提供实现）。
library;

import 'dart:convert';
import 'dart:io';

import '../sync_protocol.dart';
import '../../services/app_paths.dart';

/// token 脱敏：只保留前 4 位（设计稿 §4）。
String maskToken(String? token) {
  if (token == null || token.isEmpty) return '***';
  return token.length <= 4 ? '***' : '${token.substring(0, 4)}***';
}

/// 账号密钥存取接口（Worker C 用 flutter_secure_storage 实现，本文件不碰安全存储）。
abstract class TokenStore {
  /// 读账号 token；未配对/已删除 → null。
  Future<String?> readAccountToken(String accountId);

  /// 写账号 token（创建/重置密钥时）。
  Future<void> writeAccountToken(String accountId, String token);

  /// 删账号 token（删除账号时）。
  Future<void> deleteAccountToken(String accountId);
}

/// 服务端日志（token 必须先脱敏再打）。
void serverLog(String message) {
  // ignore: avoid_print
  print('[SyncServer] $message');
}

/// 服务端工程快照（磁盘 JSON ↔ 内存）。
class ServerSnapshot {
  final String id;
  final int rev;
  final int updatedAt;
  final String lastDeviceId;
  final String lastDeviceName;
  final Map<String, dynamic> meta;
  final String payload;
  final bool deleted;

  const ServerSnapshot({
    required this.id,
    required this.rev,
    this.updatedAt = 0,
    this.lastDeviceId = '',
    this.lastDeviceName = '',
    this.meta = const <String, dynamic>{},
    this.payload = '',
    this.deleted = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'rev': rev,
        'updatedAt': updatedAt,
        'lastDeviceId': lastDeviceId,
        'lastDeviceName': lastDeviceName,
        'meta': meta,
        'payload': payload,
        'deleted': deleted,
      };

  factory ServerSnapshot.fromJson(Map<String, dynamic> o) {
    final Object? m = o['meta'];
    final Object? d = o['deleted'];
    return ServerSnapshot(
      id: (o['id'] as String?) ?? '',
      rev: (o['rev'] as num?)?.toInt() ?? 0,
      updatedAt: (o['updatedAt'] as num?)?.toInt() ?? 0,
      lastDeviceId: (o['lastDeviceId'] as String?) ?? '',
      lastDeviceName: (o['lastDeviceName'] as String?) ?? '',
      meta: m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{},
      payload: (o['payload'] as String?) ?? '',
      deleted: d == true || (d is num && d.toInt() == 1),
    );
  }

  /// 转 `GET /index` 条目（与 [RemoteIndexEntry.fromJson] 字段对齐）。
  Map<String, dynamic> toIndexEntry() => {
        'id': id,
        'name': (meta['name'] as String?) ?? '',
        'kind': (meta['kind'] as String?) ?? 'label',
        'folder': (meta['folder'] as String?) ?? '',
        'count': (meta['count'] as num?)?.toInt() ?? 0,
        'rev': rev,
        'updatedAt': updatedAt,
        'lastDeviceId': lastDeviceId,
        'lastDeviceName': lastDeviceName,
        'deleted': deleted,
      };

  /// 转 `GET /project/:cid/history` 条目。
  Map<String, dynamic> toVersionInfo(int size) => {
        'rev': rev,
        'updatedAt': updatedAt,
        'deviceName': lastDeviceName,
        'labelCount': (meta['count'] as num?)?.toInt() ?? 0,
        'size': size,
      };
}

/// 服务端磁盘存储。
///
/// [now] 可注入（测试跨天归档用）；默认 `DateTime.now`。
class ServerStore {
  ServerStore({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  Directory? _rootCache;

  /// 服务端数据根：`<AppPaths>/ovimap-sync/`。
  Future<Directory> rootDir() async {
    final cached = _rootCache;
    if (cached != null && cached.existsSync()) return cached;
    final d = await AppPaths.syncServerDir();
    _rootCache = d;
    return d;
  }

  Future<Directory> _accountDir(String accountId) async {
    final root = await rootDir();
    final d = Directory('${root.path}/$accountId');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  /// 当天日期目录（PUT 落盘用）。
  Future<Directory> todayDir(String accountId) async {
    final acc = await _accountDir(accountId);
    final d = Directory('${acc.path}/${dateDirName(_now())}');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  // ===================== 账号 =====================

  Future<File> _accountsFile() async {
    final root = await rootDir();
    return File('${root.path}/$kAccountsFileName');
  }

  /// 读账号清单 `[{id, name, createdAt}]`（不含密钥）。
  Future<List<Map<String, dynamic>>> readAccounts() async {
    final f = await _accountsFile();
    if (!f.existsSync()) return [];
    try {
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is List) {
        return [
          for (final e in decoded)
            if (e is Map) Map<String, dynamic>.from(e)
        ];
      }
    } catch (_) {}
    return [];
  }

  Future<void> _writeAccounts(List<Map<String, dynamic>> list) async {
    final f = await _accountsFile();
    await f.writeAsString(jsonEncode(list), flush: true);
  }

  Future<void> addAccount(Map<String, dynamic> account) async {
    final list = await readAccounts();
    list.removeWhere((e) => e['id'] == account['id']);
    list.add(account);
    await _writeAccounts(list);
  }

  Future<bool> removeAccount(String accountId) async {
    final list = await readAccounts();
    final before = list.length;
    list.removeWhere((e) => e['id'] == accountId);
    if (list.length == before) return false;
    await _writeAccounts(list);
    // 级联删账号数据目录（归档/照片/设备）。
    final root = await rootDir();
    final d = Directory('${root.path}/$accountId');
    if (d.existsSync()) await d.delete(recursive: true);
    return true;
  }

  Future<Map<String, dynamic>?> findAccount(String accountId) async {
    final list = await readAccounts();
    for (final e in list) {
      if (e['id'] == accountId) return e;
    }
    return null;
  }

  // ===================== 设备 =====================

  /// 记录配对成功的设备（供 PC 端同步面板展示）。
  Future<void> recordDevice(
      String accountId, String deviceId, String deviceName) async {
    final acc = await _accountDir(accountId);
    final f = File('${acc.path}/devices.json');
    List<Map<String, dynamic>> list = [];
    if (f.existsSync()) {
      try {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is List) {
          list = [
            for (final e in decoded)
              if (e is Map) Map<String, dynamic>.from(e)
          ];
        }
      } catch (_) {}
    }
    list.removeWhere((e) => e['deviceId'] == deviceId);
    list.add({
      'deviceId': deviceId,
      'deviceName': deviceName,
      'pairedAt': _now().millisecondsSinceEpoch,
    });
    await f.writeAsString(jsonEncode(list), flush: true);
  }

  // ===================== 工程快照 =====================

  /// 快照文件名：`<cid>.r<rev>.json`（每 rev 独立文件，落当天日期目录；
  /// 同日多次 PUT 不覆盖旧 rev，`history`/`restore` 可用）。
  static String snapshotFileName(String cid, int rev) => '$cid.r$rev.json';

  static final RegExp _snapshotNameRe = RegExp(r'^(.+)\.r(\d+)\.json$');

  /// 文件名归属判定：`<cid>.r<rev>.json` 且 cid 精确匹配。
  static bool _belongsTo(File f, String cid) {
    final name = f.path.split(Platform.pathSeparator).last;
    final m = _snapshotNameRe.firstMatch(name);
    return m != null && m.group(1) == cid;
  }

  /// 该账号**所有日期目录**里的快照文件（不含 conflict 快照）。
  Future<List<File>> _snapshotFiles(String accountId) async {
    final root = await rootDir();
    final acc = Directory('${root.path}/$accountId');
    if (!acc.existsSync()) return [];
    final out = <File>[];
    await for (final e in acc.list()) {
      if (e is! Directory) continue;
      // 日期目录形如 yyyy-MM-dd；跳过 .photos 之类非日期目录。
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(
          e.path.split(Platform.pathSeparator).last)) {
        continue;
      }
      await for (final f in e.list()) {
        if (f is! File) continue;
        final name = f.path.split(Platform.pathSeparator).last;
        if (_snapshotNameRe.hasMatch(name) &&
            !name.contains('.conflict-')) {
          out.add(f);
        }
      }
    }
    return out;
  }

  /// 取某工程的最新快照（跨日期去重取最大 rev）；不存在 → null。
  Future<ServerSnapshot?> latestSnapshot(String accountId, String cid) async {
    final files = await _snapshotFiles(accountId);
    ServerSnapshot? best;
    for (final f in files) {
      if (!_belongsTo(f, cid)) continue;
      try {
        final s = ServerSnapshot.fromJson(
            Map<String, dynamic>.from(jsonDecode(await f.readAsString())));
        if (s.id != cid) continue;
        if (best == null || s.rev > best.rev) best = s;
      } catch (_) {}
    }
    return best;
  }

  /// 取某工程指定 rev 的快照（restore 用）；不存在 → null。
  Future<ServerSnapshot?> snapshotOfRev(
      String accountId, String cid, int rev) async {
    final files = await _snapshotFiles(accountId);
    for (final f in files) {
      if (!_belongsTo(f, cid)) continue;
      try {
        final s = ServerSnapshot.fromJson(
            Map<String, dynamic>.from(jsonDecode(await f.readAsString())));
        if (s.id == cid && s.rev == rev) return s;
      } catch (_) {}
    }
    return null;
  }

  /// 写快照到**当天**日期目录（PUT / DELETE / restore 统一入口）。
  Future<void> saveSnapshot(String accountId, ServerSnapshot s) async {
    final dir = await todayDir(accountId);
    final f = File('${dir.path}/${snapshotFileName(s.id, s.rev)}');
    await f.writeAsString(jsonEncode(s.toJson()), flush: true);
  }

  /// 全量索引：合并该账号所有日期目录，去重取最大 rev（deleted 照常返回，
  /// 客户端据此删本地）。
  Future<List<Map<String, dynamic>>> buildIndex(String accountId) async {
    final files = await _snapshotFiles(accountId);
    final best = <String, ServerSnapshot>{};
    for (final f in files) {
      try {
        final s = ServerSnapshot.fromJson(
            Map<String, dynamic>.from(jsonDecode(await f.readAsString())));
        if (s.id.isEmpty) continue;
        final cur = best[s.id];
        if (cur == null || s.rev > cur.rev) best[s.id] = s;
      } catch (_) {}
    }
    final items = best.values.map((s) => s.toIndexEntry()).toList();
    items.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    return items;
  }

  /// 版本历史（按 rev 倒序）。
  Future<List<Map<String, dynamic>>> history(
      String accountId, String cid) async {
    final files = await _snapshotFiles(accountId);
    final list = <ServerSnapshot>[];
    for (final f in files) {
      if (!_belongsTo(f, cid)) continue;
      try {
        final s = ServerSnapshot.fromJson(
            Map<String, dynamic>.from(jsonDecode(await f.readAsString())));
        if (s.id == cid) list.add(s);
      } catch (_) {}
    }
    list.sort((a, b) => b.rev.compareTo(a.rev));
    return [
      for (final s in list) s.toVersionInfo(utf8.encode(s.payload).length),
    ];
  }

  /// 冲突快照（"留双份"）：`<cid>.conflict-<deviceId>-<ts>.json`，
  /// 落当天日期目录。
  Future<String> saveConflictSnapshot(
    String accountId,
    ServerSnapshot attempted, {
    required int serverRev,
  }) async {
    final dir = await todayDir(accountId);
    final safeDevice =
        attempted.lastDeviceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final ts = _now().millisecondsSinceEpoch;
    final name = '${attempted.id}.conflict-$safeDevice-$ts.json';
    final f = File('${dir.path}/$name');
    await f.writeAsString(
        jsonEncode({...attempted.toJson(), 'serverRevAtConflict': serverRev}),
        flush: true);
    return name;
  }

  /// 列出某工程的冲突快照文件名（PC 端冲突合并入口用）。
  Future<List<String>> listConflictSnapshots(
      String accountId, String cid) async {
    final root = await rootDir();
    final acc = Directory('${root.path}/$accountId');
    if (!acc.existsSync()) return [];
    final out = <String>[];
    await for (final e in acc.list(recursive: true)) {
      if (e is File) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('$cid.conflict-') && name.endsWith('.json')) {
          out.add(name);
        }
      }
    }
    out.sort();
    return out;
  }

  // ===================== 照片 =====================

  /// 照片目录：`<日期>/<cid>.photos/`（与快照同天；按 sha256 去重跨天共享无妨）。
  Future<Directory> photoDir(String accountId, String cid) async {
    final dir = await todayDir(accountId);
    final d = Directory('${dir.path}/$cid.photos');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  /// 按 sha256 查找已存在的照片（去重）；返回文件，不存在 → null。
  Future<File?> findPhotoByHash(String accountId, String cid, String sha256,
      {String? onDate}) async {
    final root = await rootDir();
    final acc = Directory('${root.path}/$accountId');
    if (!acc.existsSync()) return null;
    final hash = sha256.toLowerCase();
    await for (final e in acc.list(recursive: true)) {
      if (e is! File) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (name.toLowerCase().startsWith(hash) &&
          e.path.contains('$cid.photos')) {
        return e;
      }
    }
    return null;
  }

  /// 保存照片最终文件：`<cid>.photos/<sha256>.<ext>`。
  Future<File> savePhoto(String accountId, String cid, String sha256,
      String ext, List<int> bytes) async {
    final dir = await photoDir(accountId, cid);
    final f = File('${dir.path}/${sha256.toLowerCase()}.$ext');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  // ===================== 鉴权 =====================

  /// token → accountId；token 无效 → null。比较用常量时间避免时序侧信道。
  Future<String?> accountIdForToken(TokenStore tokens, String token) async {
    if (token.isEmpty) return null;
    final accounts = await readAccounts();
    for (final a in accounts) {
      final id = (a['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      final stored = await tokens.readAccountToken(id);
      if (stored != null && _constantTimeEquals(stored, token)) return id;
    }
    return null;
  }

  /// 账号 token 验证（路由层鉴权用）。
  Future<bool> isValidToken(
      TokenStore tokens, String accountId, String token) async {
    if (token.isEmpty || accountId.isEmpty) return false;
    final stored = await tokens.readAccountToken(accountId);
    return stored != null && _constantTimeEquals(stored, token);
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  // ===================== 上传暂存 =====================

  /// 分块上传暂存根：`<root>/.uploads/`（会话结束后清理，不进归档）。
  Future<Directory> uploadStagingDir() async {
    final root = await rootDir();
    final d = Directory('${root.path}/.uploads');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }
}
