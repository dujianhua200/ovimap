import 'dart:io';

/// 稳健删除临时目录（Windows 文件锁问题）。
///
/// Windows 上文件句柄释放有延迟：测试里 fire-and-forget 的异步写盘
/// 还没完成、句柄未释放时，tearDown 立刻删临时目录会报
/// errno 32（文件正被另一进程使用）或 errno 145（目录不是空的），
/// 拖垮本已通过的测试（2026-10-15 Windows CI：import_many_folders /
/// fav_visible_d3 两文件因此失败）。
///
/// 重试 5 次，间隔递增（50ms → 100ms → 200ms → 400ms → 800ms）；
/// 全部失败时静默放弃（不让清理失败拖垮测试本身；残留临时目录由 OS 回收）。
/// 仅供测试用，生产代码不走这里。
Future<void> deleteTempDir(Directory dir) async {
  if (!dir.existsSync()) return;
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) return; // 放弃，不抛
      await Future<void>.delayed(Duration(milliseconds: 50 << attempt));
    }
  }
}
