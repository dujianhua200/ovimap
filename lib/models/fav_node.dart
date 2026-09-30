import '../services/store.dart';
import 'map_label.dart';

/// 收藏树统一节点类型（奥维式）。
enum FavKind {
  /// 文件夹 ← folders.json（支持 parentId 多级嵌套）。
  folder,

  /// 工程 ← index.json / `collection_<cid>.json`。
  project,

  /// 单个标记（虚拟节点，不落盘；由所属工程懒加载生成）。
  mark,

  /// 线组（虚拟节点，不落盘；按 lineGroupId 聚合的连续点链）。
  chain,
}

/// 收藏树统一节点（Phase 1 底座：内存统一模型）。
///
/// 磁盘格式零改动：
/// - folder / project 直接映射既有 JSON（folders.json / index.json）；
/// - mark / chain 为虚拟节点，由所属 project 懒加载生成，不单独落盘。
/// 树真相源 = 磁盘文件；绝不依赖 [AppState.overlayLabels]
/// （那是地图渲染层的"眼睛"缓存，关闭即无数据——审计问题 2）。
class FavNode {
  /// 节点全局唯一 id：
  /// - folder：Folder.id
  /// - project：CollectionMeta.id（cid）
  /// - mark：`'mark:<labelId>'`
  /// - chain：`'chain:<cid>:<lineGroupId>'`
  final String id;

  /// 父节点 id；树根为 ''。
  String pid;

  final FavKind kind;
  String name;

  // ---- 图标数据（Phase 2 渲染用；纯内存） ----
  /// ARGB 颜色；0 = 默认。
  int color;

  /// 单字符号（如 '电' / '人'）；空 = 无。
  String symbol;

  /// 形状：folder / project / chain / pin / oval / box / tri / text / vertex。
  String shape;

  // ---- 子节点（懒加载；null = 未加载） ----
  List<FavNode>? children;

  // ---- 业务引用 ----
  /// kind == folder 时有效。
  Folder? folder;

  /// kind == project 时有效。
  CollectionMeta? project;

  /// kind == mark 时有效。
  MapLabel? label;

  /// mark 所属工程 id。
  String? labelCid;

  /// kind == chain 时有效：线组 id。
  String? chainGroupId;

  /// kind == chain 时有效：所属工程 id。
  String? chainCid;

  FavNode({
    required this.id,
    required this.pid,
    required this.kind,
    required this.name,
    this.color = 0,
    this.symbol = '',
    this.shape = '',
    this.children,
    this.folder,
    this.project,
    this.label,
    this.labelCid,
    this.chainGroupId,
    this.chainCid,
  });

  bool get isFolder => kind == FavKind.folder;
  bool get isProject => kind == FavKind.project;
  bool get isMark => kind == FavKind.mark;
  bool get isChain => kind == FavKind.chain;

  /// 子节点是否已加载。
  bool get childrenLoaded => children != null;

  // ---- 工厂 ----

  factory FavNode.folderNode(Folder f) => FavNode(
        id: f.id,
        pid: f.parentId,
        kind: FavKind.folder,
        name: f.name.isEmpty ? '文件夹' : f.name,
        shape: 'folder',
        folder: f,
      );

  factory FavNode.projectNode(CollectionMeta m) => FavNode(
        id: m.id,
        pid: m.folder,
        kind: FavKind.project,
        name: m.name.isEmpty ? '未命名工程' : m.name,
        color: m.color,
        symbol: _projectSymbol(m.kind),
        shape: 'project',
        project: m,
      );

  factory FavNode.markNode(MapLabel l,
      {required String pid, required String cid}) {
    final t = l.type;
    final displayName =
        l.name.isNotEmpty ? l.name : (l.note.isNotEmpty ? l.note : t.name);
    return FavNode(
      id: 'mark:${l.id}',
      pid: pid,
      kind: FavKind.mark,
      name: displayName,
      // 点级自定义样式优先（仅显示用），否则取类型默认色。
      color: l.styleColor != 0 ? l.styleColor : t.color.toARGB32(),
      symbol: t.symbol,
      shape: t.shape,
      label: l,
      labelCid: cid,
    );
  }

  factory FavNode.chainNode({
    required String cid,
    required String groupId,
    required String pid,
    required int pointCount,
  }) =>
      FavNode(
        id: 'chain:$cid:$groupId',
        pid: pid,
        kind: FavKind.chain,
        name: '线路·$pointCount点',
        shape: 'chain',
        chainGroupId: groupId,
        chainCid: cid,
      );

  static String _projectSymbol(String kind) {
    switch (kind) {
      case LabelStore.kindTrack:
        return '迹';
      case LabelStore.kindData:
        return '测';
      case LabelStore.kindArea:
        return '区';
      case 'mark':
        return '记';
      default:
        return '项';
    }
  }

  @override
  String toString() => 'FavNode($kind, id=$id, pid=$pid, name=$name)';
}
