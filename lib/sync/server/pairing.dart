/// 同步服务端：账号管理 + 配对码（设计稿 §2.2 / §2.3）。
///
/// - `createAccount(name)` → `{accountId, token}`：token 用 `Random.secure`
///   32 字节 hex，**只返回一次**；密钥经注入的 [TokenStore] 落安全存储，
///   `accounts.json` 只存 id/名称/创建时间。
/// - 配对码：6 位数字、5 分钟有效、一次性；内存 Map + 定时清理。
/// - 失败一律抛中文 [PairingException]（HTTP 层转 400）。
library;

import 'dart:async';
import 'dart:math';

import '../sync_protocol.dart';
import 'server_store.dart';

/// 配对/账号失败（中文 message，直接展示给用户）。
class PairingException implements Exception {
  PairingException(this.message);
  final String message;

  @override
  String toString() => 'PairingException: $message';
}

class _PairCode {
  _PairCode({
    required this.accountId,
    required this.code,
    required this.expiresAt,
  });

  final String accountId;
  final String code;
  final DateTime expiresAt;
}

/// 账号管理 + 配对码服务。
///
/// [now] 可注入（测试过期用）；[enableCleanupTimer] 为 false 时不启动定时清理
/// （测试用，调用 [dispose] 释放）。
class PairingService {
  PairingService({
    required this._store,
    required this._tokens,
    DateTime Function()? now,
    Random? random,
    this.enableCleanupTimer = true,
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random.secure() {
    if (enableCleanupTimer) {
      _cleanupTimer =
          Timer.periodic(const Duration(minutes: 1), (_) => purgeExpired());
    }
  }

  final ServerStore _store;
  final TokenStore _tokens;
  final DateTime Function() _now;
  final Random _random;
  final bool enableCleanupTimer;

  Timer? _cleanupTimer;

  /// key: `$accountId:$code`
  final Map<String, _PairCode> _codes = {};

  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  /// 清理过期配对码（定时任务 + 测试可直调）。
  /// 返回清理掉的数量。
  int purgeExpired() {
    final now = _now();
    final expired = [
      for (final e in _codes.entries)
        if (!e.value.expiresAt.isAfter(now)) e.key,
    ];
    for (final k in expired) {
      _codes.remove(k);
    }
    return expired.length;
  }

  // ===================== 账号 =====================

  String _hexBytes(int n) {
    final bytes = List<int>.generate(n, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 创建账号 → `{accountId, token}`。
  ///
  /// token 只在此返回一次；调用方（PC 设置页）负责展示给用户保存。
  Future<({String accountId, String token})> createAccount(String name) async {
    final displayName = name.trim();
    if (displayName.isEmpty) {
      throw PairingException('账号名称不能为空');
    }
    final accountId = 'acc-${_hexBytes(8)}';
    final token = _hexBytes(32);
    await _tokens.writeAccountToken(accountId, token);
    await _store.addAccount({
      'id': accountId,
      'name': displayName,
      'createdAt': _now().millisecondsSinceEpoch,
    });
    serverLog('创建账号 $accountId（token=${maskToken(token)}，仅显示一次）');
    return (accountId: accountId, token: token);
  }

  /// 账号列表 `[{id, name, createdAt}]`（不含密钥）。
  Future<List<Map<String, dynamic>>> listAccounts() =>
      _store.readAccounts();

  /// 删除账号：清密钥 + 删数据目录。返回是否真的删掉了。
  Future<bool> deleteAccount(String accountId) async {
    final removed = await _store.removeAccount(accountId);
    if (!removed) {
      throw PairingException('账号不存在：$accountId');
    }
    await _tokens.deleteAccountToken(accountId);
    // 作废该账号所有未使用的配对码。
    _codes.removeWhere((k, v) => v.accountId == accountId);
    serverLog('删除账号 $accountId');
    return true;
  }

  /// 重置密钥：旧 token 立即失效，返回新 token（只返回一次）。
  Future<String> regenerateToken(String accountId) async {
    final acc = await _store.findAccount(accountId);
    if (acc == null) throw PairingException('账号不存在：$accountId');
    final token = _hexBytes(32);
    await _tokens.writeAccountToken(accountId, token);
    serverLog('账号 $accountId 重置密钥（新 token=${maskToken(token)}，仅显示一次）');
    return token;
  }

  // ===================== 配对码 =====================

  /// 签发 6 位数字配对码（5 分钟有效，一次性）。
  Future<String> issuePairCode(String accountId) async {
    final acc = await _store.findAccount(accountId);
    if (acc == null) throw PairingException('账号不存在：$accountId');
    String code;
    do {
      code =
          _random.nextInt(900000).toString().padLeft(kPairCodeDigits, '0');
      // 900000..999999 恒为 6 位；防万一补齐。
      if (code.length > kPairCodeDigits) {
        code = code.substring(code.length - kPairCodeDigits);
      }
    } while (_codes.containsKey('$accountId:$code'));
    _codes['$accountId:$code'] = _PairCode(
      accountId: accountId,
      code: code,
      expiresAt: _now().add(kPairCodeTtl),
    );
    serverLog('账号 $accountId 签发配对码（5 分钟有效）');
    return code;
  }

  /// 兑换配对码 → 该账号 token；成功后 code 立即作废。
  ///
  /// 失败抛中文 [PairingException]：账号不存在 / 配对码错误或已使用 /
  /// 配对码已过期 / 账号密钥未配置。
  Future<String> redeemPairCode(
    String accountId,
    String code,
    String deviceId,
    String deviceName,
  ) async {
    final acc = await _store.findAccount(accountId);
    if (acc == null) throw PairingException('账号不存在，请检查扫码内容');
    final key = '$accountId:${code.trim()}';
    final entry = _codes.remove(key); // 先取走：一次性，无论成功失败
    if (entry == null) {
      throw PairingException('配对码错误或已使用，请重新扫码');
    }
    if (!entry.expiresAt.isAfter(_now())) {
      throw PairingException('配对码已过期（5 分钟），请重新生成');
    }
    final token = await _tokens.readAccountToken(accountId);
    if (token == null || token.isEmpty) {
      throw PairingException('账号密钥未配置，请在电脑端重置密钥后重试');
    }
    await _store.recordDevice(accountId, deviceId, deviceName);
    serverLog('设备 $deviceName($deviceId) 配对成功，账号 $accountId');
    return token;
  }
}
