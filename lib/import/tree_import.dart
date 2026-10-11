import '../models/map_label.dart';
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
/// 写入口径（与工程向导 `applyTemplate` 同款）：
/// - 文件夹走 [FavTreeController.addFolderUndoable]；
/// - 工程走 `store.finishCollection(..., clearDraftNow: false)`，不碰当前草稿；
/// - 整个导入包成**一条** [UndoStack] 命令：外层 `execute` 的 suspend 机制
///   保证内部重入的 `execute`（如 `addFolderUndoable` 的）只执行不压栈；
///   undo = 逆序删本次建的工程 → 文件夹；redo = 重新生成。
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

  /// 确保 [path] 各级文件夹存在，返回最深层文件夹 id。
  Future<String?> ensureFolderPath(FolderPath path) async {
    var pid = parentId;
    final key = StringBuffer();
    for (final seg in path) {
      key.write('\x00$seg');
      final k = key.toString();
      final hit = pathToFolderId[k];
      if (hit != null) {
        pid = hit;
        continue;
      }
      final id = await controller.addFolderUndoable(seg, pid);
      if (id == null) return null;
      pathToFolderId[k] = id;
      createdFolderIds.add(id);
      pid = id;
    }
    return pid;
  }

  Future<bool> doIt() async {
    for (final unit in result.units) {
      final String? folderId = unit.folderPath.isEmpty
          ? parentId
          : await ensureFolderPath(unit.folderPath);
      if (folderId == null) return false;
      final cid = await store.finishCollection(
        name: unit.name,
        kind: 'design',
        folderId: folderId,
        editMode: 'design',
        labels: unit.labels,
        clearDraftNow: false,
      );
      createdProjectIds.add(cid);
      final pts = pointsOf(unit.labels);
      pointCount += pts;
      lineCount += unit.labels.length - pts;
    }
    await st.refreshCollections();
    return true;
  }

  Future<bool> undoIt() async {
    // 先删工程，再删文件夹（逆序：子文件夹先于父文件夹；
    // deleteFolder 会级联子树，逐个删保证只动本次创建的节点）。
    for (final cid in createdProjectIds.reversed) {
      try {
        await store.deleteCollection(cid);
      } catch (_) {}
    }
    for (final fid in createdFolderIds.reversed) {
      try {
        await store.deleteFolder(fid);
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
