/// 照片同步队列（手机端调用方）。
///
/// 刻意放在 [SyncController] 之外：只做"遍历本地照片 → 对服务端缺失的调
/// [uploadPhoto]"，不碰控制器内部逻辑（P1-18 的 `onRemoteApplied` 不许 regression）。
/// 同步面板「同步照片」按钮触发。
///
/// 增量：已上传成功的 sha256 记在 shared_preferences（`syncedPhotoHashes`），
/// 下次直接跳过，连 init 请求都不发。
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'photo_sync.dart';

/// 队列同步结果。
class PhotoQueueResult {
  const PhotoQueueResult({
    required this.total,
    required this.uploaded,
    required this.skipped,
    required this.failed,
  });

  final int total;
  final int uploaded;

  /// 跳过：本地已记已上传 / 服务端已有同 hash。
  final int skipped;

  /// 失败的相对文件名。
  final List<String> failed;
}

class PhotoSyncQueue {
  PhotoSyncQueue({this.httpClient});

  /// 测试注入的 HTTP 客户端；null 表示每次上传时新建。
  final http.Client? httpClient;

  /// 已上传 hash 的 prefs 键。
  static const kDoneHashesKey = 'syncedPhotoHashes';

  /// 同步一批照片。
  ///
  /// [photoRelNames] 为 `MapLabel.photoPaths` 里的相对文件名；
  /// [absPathOf] 把相对文件名转成绝对路径（生产用 `PhotoService.absPath`）。
  /// [onFileProgress] 上报 `(相对文件名, sentBytes, totalBytes)`。
  Future<PhotoQueueResult> syncAll({
    required String baseUrl,
    required String token,
    required String cid,
    required Iterable<String> photoRelNames,
    required Future<String> Function(String relName) absPathOf,
    SharedPreferences? prefs,
    void Function(String relName, int sentBytes, int totalBytes)?
    onFileProgress,
  }) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final done = Set<String>.from(
      p.getStringList(kDoneHashesKey) ?? const <String>[],
    );
    var uploaded = 0;
    var skipped = 0;
    final failed = <String>[];
    // 去重：同一文件名只传一次。
    final rels = <String>{...photoRelNames.map((e) => e.trim())}
      ..removeWhere((e) => e.isEmpty);
    for (final rel in rels) {
      try {
        final file = File(await absPathOf(rel));
        if (!file.existsSync()) {
          skipped++;
          continue;
        }
        final hash = await sha256OfFile(file);
        if (done.contains(hash)) {
          skipped++;
          continue;
        }
        final r = await uploadPhoto(
          baseUrl: baseUrl,
          token: token,
          cid: cid,
          file: file,
          client: httpClient,
          onProgress: (s, t) => onFileProgress?.call(rel, s, t),
        );
        if (r.uploaded) {
          uploaded++;
        } else {
          skipped++;
        }
        done.add(r.sha256);
      } catch (_) {
        failed.add(rel);
      }
    }
    await p.setStringList(kDoneHashesKey, done.toList());
    return PhotoQueueResult(
      total: rels.length,
      uploaded: uploaded,
      skipped: skipped,
      failed: failed,
    );
  }
}
