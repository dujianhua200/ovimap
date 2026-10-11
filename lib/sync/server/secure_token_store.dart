import '../../services/secure_store.dart';
import 'server_store.dart';

/// [TokenStore] 的 [SecureStore] 实现（Windows Credential Manager / Android Keystore）。
///
/// key 命名与 [SecureStore] 约定一致：`sync.account.<accountId>.token`。
class SecureTokenStore implements TokenStore {
  SecureTokenStore({SecureStore? store}) : _store = store ?? SecureStore.instance;

  final SecureStore _store;

  static String _key(String accountId) => 'sync.account.$accountId.token';

  @override
  Future<String?> readAccountToken(String accountId) =>
      _store.read(_key(accountId));

  @override
  Future<void> writeAccountToken(String accountId, String token) =>
      _store.write(_key(accountId), token);

  @override
  Future<void> deleteAccountToken(String accountId) =>
      _store.delete(_key(accountId));
}
