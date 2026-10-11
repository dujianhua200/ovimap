/// 照片分块上传会话（设计稿 §2.2 / §2.7）。
///
/// 流程：`init` → `chunk` ×N → `status`（断点续传）→ `complete`（合并+sha256 校验）。
/// - 分块大小固定 [kPhotoChunkSize]（256KB）。
/// - 分块暂存 `<root>/.uploads/<uploadId>/chunk_<i>`；complete 成功后按
///   sha256 落 `<cid>.photos/<sha256>.<ext>` 并清暂存。
/// - 服务端按 sha256 去重：init 时已存在同 hash 直接返回 `exists: true`。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../sync_protocol.dart';
import 'server_store.dart';

/// 照片上传失败（中文 message，HTTP 层转 400/500）。
class PhotoUploadException implements Exception {
  PhotoUploadException(this.message, {this.httpStatus = 400});
  final String message;
  final int httpStatus;

  @override
  String toString() => 'PhotoUploadException: $message';
}

class _UploadSession {
  _UploadSession({
    required this.uploadId,
    required this.accountId,
    required this.cid,
    required this.filename,
    required this.size,
    required this.sha256,
    required this.ext,
    required this.totalChunks,
    required this.createdAt,
    required this.dir,
  });

  final String uploadId;
  final String accountId;
  final String cid;
  final String filename;
  final int size;
  final String sha256;
  final String ext;
  final int totalChunks;
  final DateTime createdAt;
  final Directory dir;

  /// 已收到的分块位图。
  final List<bool> received = [];

  bool get expired =>
      DateTime.now().difference(createdAt) > kUploadSessionTtl;

  File chunkFile(int i) => File('${dir.path}/chunk_$i');
}

/// 照片分块上传管理器（会话在内存，会话目录在磁盘暂存）。
class PhotoUploadManager {
  PhotoUploadManager({required this._store, Random? random})
      : _random = random ?? Random.secure();

  final ServerStore _store;
  final Random _random;

  final Map<String, _UploadSession> _sessions = {};

  String _newUploadId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _extOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return 'jpg';
    final ext = filename.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext) ? ext : 'jpg';
  }

  /// 清理过期会话（含磁盘暂存）。返回清理数。
  Future<int> purgeExpired() async {
    final expired = [
      for (final e in _sessions.entries)
        if (e.value.expired) e.key,
    ];
    for (final id in expired) {
      await _drop(id);
    }
    return expired.length;
  }

  Future<void> _drop(String uploadId) async {
    final s = _sessions.remove(uploadId);
    if (s != null && s.dir.existsSync()) {
      try {
        await s.dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// `POST .../photos/init`：`{filename, size, sha256}` →
  /// `{uploadId, chunkSize, totalChunks, exists}`。
  ///
  /// 同一账号下已存在同 sha256 的照片 → `exists: true`（客户端可跳过上传）。
  Future<Map<String, dynamic>> init(
    String accountId,
    String cid, {
    required String filename,
    required int size,
    required String sha256,
  }) async {
    if (filename.isEmpty) throw PhotoUploadException('文件名不能为空');
    if (size <= 0 || size > 100 * 1024 * 1024) {
      throw PhotoUploadException('文件大小非法（须在 0~100MB 之间）');
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw PhotoUploadException('sha256 格式非法（须为 64 位 hex）');
    }
    final exists =
        await _store.findPhotoByHash(accountId, cid, sha256) != null;
    final uploadId = _newUploadId();
    final staging = await _store.uploadStagingDir();
    final dir = Directory('${staging.path}/$uploadId');
    await dir.create(recursive: true);
    final totalChunks = (size + kPhotoChunkSize - 1) ~/ kPhotoChunkSize;
    final session = _UploadSession(
      uploadId: uploadId,
      accountId: accountId,
      cid: cid,
      filename: filename,
      size: size,
      sha256: sha256.toLowerCase(),
      ext: _extOf(filename),
      totalChunks: totalChunks,
      createdAt: DateTime.now(),
      dir: dir,
    );
    session.received.addAll(List<bool>.filled(totalChunks, false));
    _sessions[uploadId] = session;
    serverLog('照片上传初始化 $filename（$size字节，$totalChunks 块，'
        'sha256=${sha256.substring(0, 8)}…，已存在=$exists）');
    return {
      'uploadId': uploadId,
      'chunkSize': kPhotoChunkSize,
      'totalChunks': totalChunks,
      'exists': exists,
    };
  }

  _UploadSession _sessionOf(String uploadId) {
    final s = _sessions[uploadId];
    if (s == null) {
      throw PhotoUploadException('上传会话不存在或已过期，请重新初始化');
    }
    if (s.expired) {
      _drop(uploadId);
      throw PhotoUploadException('上传会话已过期（24 小时），请重新初始化');
    }
    return s;
  }

  /// `PUT .../chunk/:i`：写入分块（octet-stream）。返回已收块数。
  Future<int> putChunk(
      String uploadId, int index, List<int> bytes) async {
    final s = _sessionOf(uploadId);
    if (index < 0 || index >= s.totalChunks) {
      throw PhotoUploadException('分块序号越界：$index（共 ${s.totalChunks} 块）');
    }
    if (bytes.isEmpty || bytes.length > kPhotoChunkSize) {
      throw PhotoUploadException('分块大小非法');
    }
    await s.chunkFile(index).writeAsBytes(bytes, flush: true);
    s.received[index] = true;
    final done = s.received.where((b) => b).length;
    return done;
  }

  /// `GET .../status`：已上传分块位图（断点续传）。
  Map<String, dynamic> status(String uploadId) {
    final s = _sessionOf(uploadId);
    return {
      'uploadId': uploadId,
      'totalChunks': s.totalChunks,
      'received': List<bool>.from(s.received),
      'done': s.received.where((b) => b).length,
    };
  }

  /// `POST .../complete`：校验分块齐全 → 合并 → sha256 校验 → 落盘。
  ///
  /// 成功返回 `{sha256, size, path}`；缺块或 hash 不符抛
  /// [PhotoUploadException]（HTTP 400）。
  Future<Map<String, dynamic>> complete(String uploadId) async {
    final s = _sessionOf(uploadId);
    final missing = [
      for (var i = 0; i < s.totalChunks; i++)
        if (!s.received[i]) i,
    ];
    if (missing.isNotEmpty) {
      throw PhotoUploadException(
          '分块缺失（${missing.length} 块：${missing.take(8).join(',')}…），请断点续传');
    }
    // 合并。
    final sink = BytesBuilder();
    for (var i = 0; i < s.totalChunks; i++) {
      final f = s.chunkFile(i);
      if (!f.existsSync()) {
        throw PhotoUploadException('分块文件丢失：$i，请重新上传');
      }
      sink.add(await f.readAsBytes());
    }
    final bytes = sink.toBytes();
    if (bytes.length != s.size) {
      throw PhotoUploadException(
          '合并后大小不符（期望 ${s.size}，实际 ${bytes.length}）');
    }
    final digest = sha256.convert(bytes).toString();
    if (digest != s.sha256) {
      await _drop(uploadId);
      throw PhotoUploadException('sha256 校验失败，数据已丢弃请重传');
    }
    final file =
        await _store.savePhoto(s.accountId, s.cid, s.sha256, s.ext, bytes);
    await _drop(uploadId);
    serverLog('照片落盘 ${s.filename} → ${file.path}（${bytes.length}字节）');
    return {
      'sha256': s.sha256,
      'size': bytes.length,
      'path': file.path,
    };
  }
}
