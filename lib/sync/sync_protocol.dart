/// 同步服务端/客户端共享协议常量。
///
/// 三端（Windows 服务端、手机客户端、Cloudflare Tunnel 地址）共用，
/// 避免魔法数字散落各处。纯常量，无 IO，可零依赖单测。
library;

/// HTTP 服务默认端口。
const int kSyncServerPort = 47820;

/// UDP 局域网发现端口。
const int kSyncDiscoveryPort = 47821;

/// UDP 发现广播魔串（v1）。
const String kDiscoveryMagic = 'OVIMAP_SYNC/1';

/// 服务端广播间隔。
const Duration kDiscoveryBeaconInterval = Duration(seconds: 5);

/// 手机端监听窗口。
const Duration kDiscoveryListenWindow = Duration(seconds: 3);

// ---- REST 路径（与既有 SyncApi 兼容，新增配对/照片/WS）----

const String kPathPing = '/ping';
const String kPathIndex = '/index';
const String kPathPair = '/pair';
const String kPathWs = '/ws';

String projectPath(String cid) => '/project/$cid';
String projectHistoryPath(String cid) => '/project/$cid/history';
String projectRestorePath(String cid) => '/project/$cid/restore';
String photoInitPath(String cid) => '/project/$cid/photos/init';
String photoChunkPath(String cid, String uploadId, int index) =>
    '/project/$cid/photos/$uploadId/chunk/$index';
String photoStatusPath(String cid, String uploadId) =>
    '/project/$cid/photos/$uploadId/status';
String photoCompletePath(String cid, String uploadId) =>
    '/project/$cid/photos/$uploadId/complete';

// ---- 配对 ----

/// 配对码位数。
const int kPairCodeDigits = 6;

/// 配对码有效期。
const Duration kPairCodeTtl = Duration(minutes: 5);

/// 二维码载荷版本。
const int kQrPayloadVersion = 1;

// ---- 照片分块 ----

/// 照片分块大小（256KB，弱网友好）。
const int kPhotoChunkSize = 256 * 1024;

/// 上传会话有效期（断点续传窗口）。
const Duration kUploadSessionTtl = Duration(hours: 24);

// ---- 服务端磁盘布局 ----

/// 服务端数据根（相对 AppData）。
const String kServerDataDirName = 'ovimap-sync';

/// 账号清单文件名。
const String kAccountsFileName = 'accounts.json';

/// 日期目录格式（yyyy-MM-dd）。
String dateDirName(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-'
    '${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')}';

// ---- cloudflared ----

/// cloudflared pinned 版本（运行时下载）。
const String kCloudflaredVersion = '2026.1.1';

/// Windows 可执行文件名。
const String kCloudflaredExe = 'cloudflared.exe';

String cloudflaredDownloadUrl(String version) =>
    'https://github.com/cloudflare/cloudflared/releases/download/'
    '$version/cloudflared-windows-amd64.exe';
