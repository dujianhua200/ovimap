import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 同步密钥的安全存储封装（Worker C：Worker A 服务端鉴权、Worker B 配对 token 的共同依赖）。
///
/// - Windows：Windows Credential Manager；Android：Android Keystore。
/// - **密钥绝不进普通配置文件**，不打完整日志（用 [maskSecret] 脱敏）。
///
/// 接口保持最小稳定：[read] / [write] / [delete]（另附 [deleteAll]），
/// key 命名见 [accountTokenKey] / [serverTokenKey] / [kTunnelTokenKey]。
///
/// 测试友好：构造函数可注入 [FlutterSecureStorage]，测试用内存 Map 实现的
/// `FakeSecureStore`（见 `test/sync_tunnel_test.dart`）。
class SecureStore {
  /// 生产单例。
  static final SecureStore instance = SecureStore();

  /// [storage] 可注入（测试用 fake）；缺省走平台安全存储。
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> delete(String key) => _storage.delete(key: key);

  Future<void> deleteAll() => _storage.deleteAll();
}

/// 账号 token 的 key：`sync.account.<accountId>.token`。
String accountTokenKey(String accountId) => 'sync.account.$accountId.token';

/// 服务端 token 的 key：`sync.server.<name>.token`。
String serverTokenKey(String name) => 'sync.server.$name.token';

/// Cloudflare Tunnel token 的 key。
const String kTunnelTokenKey = 'sync.tunnel.token';

/// 日志脱敏：`abcd1234…` → `abcd***`。
///
/// - `null` / 空字符串 → `(空)`
/// - 不足 4 位 → 全星号（与原长度等长）
String maskSecret(String? secret) {
  if (secret == null || secret.isEmpty) return '(空)';
  if (secret.length < 4) return '*' * secret.length;
  return '${secret.substring(0, 4)}***';
}
