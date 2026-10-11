/// 照片分块上传（手机端）：sha256 → init → status（断点续传）→
/// 256KB 分块 PUT（失败重试 3 次，指数退避 1s/2s/4s）→ complete 校验。
///
/// 服务端契约（设计稿 §2.2/§2.7，Worker A 实现）：
/// - `POST /project/:cid/photos/init` `{sha256,size,name}` →
///   `{uploadId, chunkSize, exists}`（`exists:true` 表示服务端已有同 hash，直接跳过）
/// - `GET /project/:cid/photos/:uid/status` → `{uploaded:[0,2,…]}`（或 `{bitmap:"101"}`）
/// - `PUT /project/:cid/photos/:uid/chunk/:i` 二进制 body（`application/octet-stream`）
/// - `POST /project/:cid/photos/:uid/complete` `{sha256}` → `{sha256}`（合并后校验）
/// 统一响应体 `{code, data, message}`；401 → token 无效。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../sync_protocol.dart';

/// 照片上传异常（message 均为中文，直接展示）。
class PhotoSyncException implements Exception {
  PhotoSyncException(this.message);
  final String message;

  @override
  String toString() => 'PhotoSyncException: $message';
}

/// 单张照片上传结果。
class PhotoUploadResult {
  const PhotoUploadResult({
    required this.sha256,
    required this.size,
    required this.uploaded,
  });

  final String sha256;
  final int size;

  /// false = 服务端已有同 hash，跳过上传。
  final bool uploaded;
}

/// 字节 sha256（hex 小写）。
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// 文件 sha256（流式，大文件不爆内存）。
Future<String> sha256OfFile(File file) =>
    sha256.bind(file.openRead()).first.then((d) => d.toString());

String _base(String baseUrl) => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

Map<String, String> _auth(String token) => {
  'Authorization': 'Bearer $token',
  'Accept': 'application/json',
};

/// 解析统一响应体；401/业务码非 0 → 抛中文异常；返回 `data`。
Map<String, dynamic> _dataOf(http.Response r, String action) {
  Map<String, dynamic>? env;
  try {
    final decoded = jsonDecode(utf8.decode(r.bodyBytes));
    if (decoded is Map) env = Map<String, dynamic>.from(decoded);
  } catch (_) {}
  if (r.statusCode == 401) {
    throw PhotoSyncException('同步令牌无效（401），请重新配对');
  }
  final bizCode = (env?['code'] as num?)?.toInt();
  if (r.statusCode >= 400 || (bizCode != null && bizCode != 0)) {
    final msg = (env?['message'] as String? ?? '').trim();
    throw PhotoSyncException(
      msg.isEmpty ? '$action失败（HTTP ${r.statusCode}）' : '$action失败：$msg',
    );
  }
  final data = env?['data'];
  return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
}

/// 从 status 响应解析已上传分块下标（兼容 `uploaded:[...]` 与 `bitmap:"101"`）。
Set<int> _parseUploaded(Map<String, dynamic> data) {
  final out = <int>{};
  final list = data['uploaded'];
  if (list is List) {
    for (final e in list) {
      if (e is num) out.add(e.toInt());
    }
    return out;
  }
  final bitmap = data['bitmap'];
  if (bitmap is String) {
    for (var i = 0; i < bitmap.length; i++) {
      if (bitmap[i] == '1') out.add(i);
    }
  }
  return out;
}

/// 上传单张照片（断点续传 + 分块重试）。
///
/// [onProgress] 上报 `(sentBytes, totalBytes)`（含跳过的已传分块）。
/// [sleeper] 可注入（测试用零延迟）；缺省 `Future.delayed`。
Future<PhotoUploadResult> uploadPhoto({
  required String baseUrl,
  required String token,
  required String cid,
  required File file,
  http.Client? client,
  void Function(int sentBytes, int totalBytes)? onProgress,
  Future<void> Function(Duration)? sleeper,
}) async {
  final base = _base(baseUrl);
  if (base.isEmpty) throw PhotoSyncException('服务器地址为空');
  if (cid.isEmpty) throw PhotoSyncException('工程 ID 为空');
  if (!file.existsSync()) throw PhotoSyncException('照片文件不存在：${file.path}');
  final c = client ?? http.Client();
  final sleep = sleeper ?? Future.delayed;
  final headers = _auth(token);

  final bytes = await file.readAsBytes();
  final hash = sha256Hex(bytes);
  final total = bytes.length;
  final name = file.uri.pathSegments.isEmpty ? '' : file.uri.pathSegments.last;

  Future<http.Response> postJson(String path, Map<String, Object?> body) =>
      c.post(
        Uri.parse('$base$path'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

  // ---- init ----
  final initData = _dataOf(
    await postJson(photoInitPath(cid), {
      'sha256': hash,
      'size': total,
      'name': name,
    }),
    '照片上传初始化',
  );
  if (initData['exists'] == true) {
    onProgress?.call(total, total);
    return PhotoUploadResult(sha256: hash, size: total, uploaded: false);
  }
  final uploadId = (initData['uploadId'] as String? ?? '').trim();
  if (uploadId.isEmpty) throw PhotoSyncException('照片上传初始化失败：服务端未返回 uploadId');
  final chunkSize = (initData['chunkSize'] as num?)?.toInt() ?? kPhotoChunkSize;

  // ---- status：已传分块 ----
  final statusData = _dataOf(
    await c.get(
      Uri.parse('$base${photoStatusPath(cid, uploadId)}'),
      headers: headers,
    ),
    '查询上传进度',
  );
  final done = _parseUploaded(statusData);

  // ---- 分块 PUT（失败重试 3 次：1s / 2s / 4s 退避） ----
  final chunkCount = total == 0 ? 0 : (total / chunkSize).ceil();
  var sent = 0;
  for (var i = 0; i < chunkCount; i++) {
    final start = i * chunkSize;
    final end = (start + chunkSize > total) ? total : start + chunkSize;
    final chunkLen = end - start;
    if (done.contains(i)) {
      sent += chunkLen;
      onProgress?.call(sent, total);
      continue;
    }
    var attempt = 0;
    while (true) {
      try {
        final r = await c.put(
          Uri.parse('$base${photoChunkPath(cid, uploadId, i)}'),
          headers: {...headers, 'Content-Type': 'application/octet-stream'},
          body: bytes.sublist(start, end),
        );
        _dataOf(r, '上传分块 $i');
        break;
      } catch (e) {
        attempt++;
        if (attempt > 3) {
          throw PhotoSyncException(
            '上传分块 $i 失败（已重试 3 次）：'
            '${e is PhotoSyncException ? e.message : e}',
          );
        }
        await sleep(Duration(seconds: 1 << (attempt - 1))); // 1s / 2s / 4s
      }
    }
    sent += chunkLen;
    onProgress?.call(sent, total);
  }

  // ---- complete：合并 + sha256 校验 ----
  final completeData = _dataOf(
    await postJson(photoCompletePath(cid, uploadId), {'sha256': hash}),
    '照片合并',
  );
  final serverHash = (completeData['sha256'] as String? ?? '').trim();
  if (serverHash.isNotEmpty && serverHash != hash) {
    throw PhotoSyncException('照片校验失败：服务端合并后的 sha256 与本地不一致');
  }
  onProgress?.call(total, total);
  return PhotoUploadResult(sha256: hash, size: total, uploaded: true);
}
