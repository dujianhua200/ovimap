import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app_paths.dart';
import '../../services/secure_store.dart';
import '../sync_protocol.dart';

/// cloudflared-windows-amd64.exe（版本 2026.1.1，见 [kCloudflaredVersion]）
/// 的官方 SHA-256。
///
/// 来源：https://github.com/cloudflare/cloudflared/releases/tag/2026.1.1
/// release notes「SHA256 Checksums」段（2026-10-11 Worker C 查得）。
/// 下载后严格比对，不匹配则删除文件并抛错。
const String kCloudflaredWindowsAmd64Sha256 =
    '75b28989df6a4ed3805732c5c3245c2058481a56cf9f11693e067e1339a6d0aa';

/// 「启用远程同步」开关（shared_preferences）。
const String kTunnelEnabledPrefKey = 'syncTunnelEnabled';

/// 用户填的远程地址（如 `https://sync.xxx.com`，shared_preferences）。
const String kTunnelUrlPrefKey = 'syncTunnelUrl';

/// 下载进度回调：(已收字节, 总字节；未知时为 -1)。
typedef DownloadProgressCallback = void Function(int received, int total);

/// cloudflared 子进程的最小抽象（`Process.start` 可注入，方便单测）。
abstract class TunnelProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  bool kill();
}

class _IoTunnelProcess implements TunnelProcess {
  _IoTunnelProcess(this._p);
  final Process _p;

  @override
  Stream<List<int>> get stdout => _p.stdout;
  @override
  Stream<List<int>> get stderr => _p.stderr;
  @override
  Future<int> get exitCode => _p.exitCode;
  @override
  bool kill() => _p.kill();
}

/// `Process.start` 的可注入包装类型。
typedef TunnelProcessFactory = Future<TunnelProcess> Function(
    String exe, List<String> args);

Future<TunnelProcess> _defaultProcessFactory(String exe, List<String> args) =>
    Process.start(exe, args).then(_IoTunnelProcess.new);

/// Cloudflare Tunnel sidecar（cloudflared.exe）管理器。
///
/// 仅 Windows 生效：其他平台 [ensureBinary] 直接抛中文错误。
/// token 绝不进日志——日志里出现的 token 都会被 [maskSecret] 脱敏。
class TunnelManager extends ChangeNotifier {
  TunnelManager({
    bool? isWindows,
    TunnelProcessFactory? processFactory,
    Future<String> Function()? binaryPathProvider,
    SecureStore? secureStore,
    String? expectedSha256,
  })  : _isWindows = isWindows ?? Platform.isWindows,
        _processFactory = processFactory ?? _defaultProcessFactory,
        _binaryPathProvider =
            binaryPathProvider ?? _defaultBinaryPathProvider,
        _secureStore = secureStore ?? SecureStore.instance,
        _expectedSha256 = expectedSha256 ?? kCloudflaredWindowsAmd64Sha256;

  final bool _isWindows;
  final TunnelProcessFactory _processFactory;
  final Future<String> Function() _binaryPathProvider;
  final SecureStore _secureStore;
  final String _expectedSha256;

  static Future<String> _defaultBinaryPathProvider() async {
    final base = await AppPaths.baseDir();
    return '${base.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}$kCloudflaredExe';
  }

  TunnelProcess? _process;
  bool _running = false;

  /// 子进程是否运行中。
  bool get running => _running;

  bool _downloading = false;

  /// 是否正在下载 cloudflared。
  bool get downloading => _downloading;

  /// 下载进度（0..1；总长度未知时为 null）。
  double? _downloadProgress;
  double? get downloadProgress => _downloadProgress;

  String? _lastError;

  /// 最近一次错误（中文）。
  String? get lastError => _lastError;

  final List<String> _logLines = [];

  /// 最近 50 行日志（token 已脱敏），供 UI 显示。
  List<String> get logLines => List.unmodifiable(_logLines);

  void _requireWindows() {
    if (!_isWindows) {
      throw StateError('Cloudflare Tunnel 仅 Windows 服务端支持');
    }
  }

  void _appendLog(String line, [String token = '']) {
    final masked = token.isEmpty
        ? line
        : line.replaceAll(token, maskSecret(token));
    _logLines.add(masked);
    if (_logLines.length > 50) {
      _logLines.removeRange(0, _logLines.length - 50);
    }
  }

  /// cloudflared.exe 是否已存在。
  Future<bool> binaryExists() async {
    _requireWindows();
    return File(await _binaryPathProvider()).exists();
  }

  /// 确保二进制存在：不存在则下载 + sha256 校验。返回 exe 路径。
  Future<String> ensureBinary(
      {DownloadProgressCallback? onProgress}) async {
    _requireWindows();
    final path = await _binaryPathProvider();
    final file = File(path);
    if (await file.exists()) return path;

    _downloading = true;
    _downloadProgress = null;
    _lastError = null;
    notifyListeners();
    try {
      await _download(file, onProgress);
      await _verifyBinary(file);
      _appendLog('cloudflared 下载完成并通过校验：$path');
      return path;
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    } finally {
      _downloading = false;
      _downloadProgress = null;
      notifyListeners();
    }
  }

  Future<void> _download(
      File file, DownloadProgressCallback? onProgress) async {
    final url = cloudflaredDownloadUrl(kCloudflaredVersion);
    _appendLog('开始下载 cloudflared $kCloudflaredVersion …');
    await file.parent.create(recursive: true);
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw StateError('下载失败：HTTP ${resp.statusCode}（$url）');
      }
      final total = resp.contentLength;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
        _downloadProgress =
            total > 0 ? received / total : null;
        notifyListeners();
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<void> _verifyBinary(File file) async {
    final expected = _expectedSha256.trim();
    if (expected.isNotEmpty) {
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual.toLowerCase() != expected.toLowerCase()) {
        await file.delete();
        throw StateError('cloudflared 校验失败（sha256 不匹配），已删除下载文件');
      }
      return;
    }
    // 兜底（未查到官方 hash 时）：大小 > 10MB 且能 --version 运行。
    final size = await file.length();
    if (size <= 10 * 1024 * 1024) {
      await file.delete();
      throw StateError('下载文件过小（$size 字节），可能下载不完整，已删除');
    }
    final result = await Process.run(file.path, const ['--version']);
    if (result.exitCode != 0) {
      await file.delete();
      throw StateError('cloudflared --version 运行失败，已删除下载文件');
    }
  }

  /// 拉起隧道。token 从安全存储读，**绝不拼进日志**（只打脱敏后的前 4 位）。
  Future<void> start(String token) async {
    _requireWindows();
    if (_running) return;
    final path = await _binaryPathProvider();
    if (!await File(path).exists()) {
      throw StateError('cloudflared 二进制不存在，请先下载');
    }
    if (token.trim().isEmpty) {
      throw StateError('Tunnel token 为空，请先在设置页保存 token');
    }
    _lastError = null;
    final proc = await _processFactory(
        path, ['tunnel', '--no-autoupdate', 'run', '--token', token]);
    _process = proc;
    _running = true;
    _appendLog('启动 cloudflared（token ${maskSecret(token)}）…', token);
    _attachListeners(proc, token);
    notifyListeners();
  }

  void _attachListeners(TunnelProcess proc, String token) {
    void onLine(String line) {
      _appendLog(line, token);
      notifyListeners();
    }

    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(onLine);
    proc.exitCode.then((code) {
      if (_process == proc) {
        _process = null;
        _running = false;
        _appendLog('cloudflared 退出（code=$code）');
        notifyListeners();
      }
    });
  }

  /// 停止隧道（杀进程）。
  void stop() {
    final proc = _process;
    _process = null;
    _running = false;
    if (proc != null) {
      proc.kill();
      _appendLog('已停止 cloudflared');
    }
    notifyListeners();
  }

  /// App 启动时调用：若用户打开了「启用远程同步」开关且存有 token，
  /// 自动 `ensureBinary` + `start`。**本方法不改 AppState**，调用方
  /// （AppState 初始化处）负责在启动流程里调一次。
  ///
  /// 全链路吞异常：失败只记 [lastError]，不抛。
  Future<void> autoStartIfEnabled() async {
    if (!_isWindows) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(kTunnelEnabledPrefKey) ?? false)) return;
      final token = await _secureStore.read(kTunnelTokenKey);
      if (token == null || token.trim().isEmpty) {
        _lastError = '已启用远程同步，但尚未保存 Tunnel token';
        notifyListeners();
        return;
      }
      await ensureBinary();
      await start(token);
    } catch (e) {
      _lastError = '隧道自动启动失败：$e';
      notifyListeners();
    }
  }
}
