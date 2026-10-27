import '../models/map_label.dart';
import '../services/store.dart';
import '../state/fav_tree_controller.dart';
import 'import_model.dart';

/// 单次"解析结果 → 收藏夹树"导入的落点统计。
class ImportTreeResult {
  /// 整个导入是否成功写入（失败时不压撤销栈）。
  final bool ok;

  /// 本次新建的文件夹数。
  final int folderCount;

  /// 本次新建的工程数。
  final int projectCount;

  /// 本次导入的点要素数（无 lineGroupId 的标签）。
  final int pointCount;

  /// 本次导入的线要素标签数（带 lineGroupId 的标签）。
  final int lineCount;

  /// 本次新建的文件夹 id（按创建顺序）。
  final List<String> folderIds;

  /// 本次新建的工程 id（按创建顺序）。
  final List<String> projectIds;

  const ImportTreeResult({
    required this.ok,
    this.folderCount = 0,
    this.projectCount = 0,
    this.pointCount = 0,
    this.lineCount = 0,
    this.folderIds = const [],
    this.projectIds = const [],
  });
}

/// 解析结果 → 收藏夹统一树（落点 B：保留 Folder 层级）。
///
/// 映射规则：
/// - [ImportUnit.folderPath] 非空 → 按路径逐层建同名嵌套文件夹
///   （顶层建在 [parentId] 下，`''` = 根；跨 unit 的同名路径复用已建文件夹）；
/// - 该路径直属的要素集合 → 最深层文件夹内建一个工程（名 = [ImportUnit.name]）；
/// - `folderPath` 为空 → 不建文件夹，直接在 [parentId] 下建一个工程
///   （名 = [ImportUnit.name]；解析器侧已用 [baseNameWithoutExt] 把
///   文件名去扩展名填入，无 Folder 的源文件就只得到这一个工程）；
/// - 同名不拦截（store 按 id 区分，沿用现有行为）。
///
/// 写入口径：
/// - 文件夹批量建：先收集全部去重路径，按深度分层、每层一次
///   `store.addFolders`（一次读+写建完一层，父先于子）；不要逐个调
///   `addFolderUndoable`——它每次都要全量读+写 folders.json + 刷新，
///   F 个文件夹就是 O(F²)，1800 个文件夹实测超时 30 秒（ovkml 导入卡死根因）；
/// - 工程走 `store.finishCollection(..., clearDraftNow: false)`，不碰当前草稿；
/// - 整个导入包成**一条** [UndoStack] 命令：外层 `execute` 的 suspend 机制
///   保证内部重入的 `execute` 只执行不压栈；undo = 批量删本次建的工程 →
///   文件夹（同样一次索引/文件夹读写，避免撤销时再 O(n²)）；redo = 重新生成。
Future<ImportTreeResult> importParsedResult(
  FavTreeController controller,
  ImportParseResult result, {
  String parentId = '',
}) async {
  final store = controller.store;
  final st = controller.appState;

  final createdFolderIds = <String>[];
  final createdProjectIds = <String>[];
  // 完整路径（'\x00' 连接各级名）→ 已建文件夹 id：同名嵌套逐层对应。
  final pathToFolderId = <String, String>{};
  var pointCount = 0;
  var lineCount = 0;

  int pointsOf(List<MapLabel> labels) =>
      labels.where((l) => l.lineGroupId.isEmpty).length;

  /// 批量建全部去重文件夹路径（按深度分层，每层一次写盘）。
  /// 失败返回 false（调用方视为导入失败，不压撤销栈）。
  Future<bool> createAllFolders() async {
    // 收集全部去重路径（key → 路径），含各路径的每个前缀。
    final paths = <String, FolderPath>{};
    for (final unit in result.units) {
      final path = unit.folderPath;
      if (path.isEmpty) continue;
      final buf = StringBuffer();
      for (var d = 0; d < path.length; d++) {
        buf.write('\x00${path[d]}');
        paths.putIfAbsent(buf.toString(), () => path.sublist(0, d + 1));
      }
    }
    if (paths.isEmpty) return true;
    // 按深度分组，浅层先建（父文件夹 id 须在子层建之前已知）。
    final byDepth = <int, List<MapEntry<String, FolderPath>>>{};
    for (final e in paths.entries) {
      (byDepth[e.value.length] ??= []).add(e);
    }
    final depths = byDepth.keys.toList()..sort();
    for (final depth in depths) {
      final batch = <Folder>[];
      for (final e in byDepth[depth]!) {
        final path = e.value;
        // 父路径 key：顶层（depth==1）父级 = parentId；否则查已建映射。
        final parentKey = depth == 1
            ? ''
            : path.sublist(0, path.length - 1).map((s) => '\x00$s').join();
        final pid = parentKey.isEmpty ? parentId : pathToFolderId[parentKey];
        if (pid == null) return false; // 父级缺失（不应发生：深度顺序保证）
        batch.add(Folder(MapLabel().id, path.last, pid));
      }
      final created = await store.addFolders(batch);
      for (var i = 0; i < byDepth[depth]!.length; i++) {
        final key = byDepth[depth]![i].key;
        pathToFolderId[key] = created[i].id;
        createdFolderIds.add(created[i].id);
      }
    }
    return true;
  }

  Future<bool> doIt() async {
    if (!await createAllFolders()) return false;
    // 批量建工程：逐个写文件 + 一次索引读写（避免逐个 finishCollection 的
    // O(P²) 索引读写；与文件夹批量同理）。
    final specs = <CollectionWrite>[];
    for (final unit in result.units) {
      final String? folderId = unit.folderPath.isEmpty
          ? parentId
          : pathToFolderId[unit.folderPath.map((s) => '\x00$s').join()];
      if (folderId == null) return false;
      specs.add(
        CollectionWrite(
          name: unit.name,
          kind: 'design',
          folderId: folderId,
          editMode: 'design',
          labels: unit.labels,
        ),
      );
    }
    final cids = await store.finishCollections(specs);
    createdProjectIds.addAll(cids);
    for (final unit in result.units) {
      final pts = pointsOf(unit.labels);
      pointCount += pts;
      lineCount += unit.labels.length - pts;
    }
    await st.refreshCollections();
    return true;
  }

  Future<bool> undoIt() async {
    // 先删工程，再删文件夹（批量：各一次索引/文件夹读写）。
    if (createdProjectIds.isNotEmpty) {
      try {
        final ids = List<String>.of(createdProjectIds);
        await store.deleteCollections(ids);
        // 批量删文件后同步清状态：否则导入期间显示到地图的工程/正在编辑的草稿
        // 会继续留在地图上（与单个删除的"删了还在"同类）。
        st.forgetDeletedCollections(ids);
      } catch (_) {}
    }
    if (createdFolderIds.isNotEmpty) {
      try {
        await store.deleteFolders(createdFolderIds);
      } catch (_) {}
    }
    pathToFolderId.clear();
    createdFolderIds.clear();
    createdProjectIds.clear();
    pointCount = 0;
    lineCount = 0;
    await st.refreshCollections();
    return true;
  }

  final ok = await st.undoStack.execute(
    '导入对象文件（${result.units.length} 个工程）',
    doIt,
    undoIt,
  );
  return ImportTreeResult(
    ok: ok,
    folderCount: createdFolderIds.length,
    projectCount: createdProjectIds.length,
    pointCount: pointCount,
    lineCount: lineCount,
    folderIds: List<String>.unmodifiable(createdFolderIds),
    projectIds: List<String>.unmodifiable(createdProjectIds),
  );
}
