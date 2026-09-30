import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/fav_node.dart';
import '../models/map_label.dart';
import '../services/store.dart';
import 'app_state.dart';

/// 收藏树统一控制器（Phase 1：模型 + 控制器；UI 在 Phase 2 接入）。
///
/// 核心约束（DESIGN.md §1 + 审计报告 §6-§7）：
/// - 树真相源 = folders.json / index.json / `collection_<cid>.json` 磁盘文件；
///   绝不依赖 [AppState.overlayLabels]（它只在"眼睛打开"时有数据，
///   是地图渲染层——审计问题 2）。点位统一走 [_labelCache] +
///   `store.loadCollection` 懒加载。
/// - 磁盘格式零改动：可见性以可选字段 `visible` 读写 index.json
///   （纯加法，旧版忽略；读时缺省 true）。
/// - 不读写 [AppState.folderId]（它一身二任：树选中层 + 草稿保存目标层——
///   审计问题 9）；树选中层用 [treeSelectedFolderId] 独立维护。
/// - 计数包含标记（审计问题 10）：[countOf] 统计工程数 + 各工程内点数。
class FavTreeController extends ChangeNotifier {
  FavTreeController(this._st) {
    _st.addListener(_onAppState);
    _ready = _init();
  }

  final AppState _st;
  LabelStore get _store => _st.store;

  // ---------- Phase 2 共享组件用的公开访问（纯加法） ----------

  /// 宿主 [AppState]（回收站/显隐联动等共享组件用）。
  AppState get appState => _st;

  /// 底层 [LabelStore]（回收站读写 trash.json 等用；不绕过磁盘格式）。
  LabelStore get store => _store;

  /// 点位真相源（公开版 [_labelsOf]）：含未展开工程的 labels，走磁盘缓存，
  /// 绝不读 [AppState.overlayLabels]。返回拷贝，调用方不要原地修改。
  Future<List<MapLabel>> labelsOf(String cid) async =>
      List<MapLabel>.of(await _labelsOf(cid));

  /// 全部文件夹 / 工程节点（搜索、全选、文件夹选择器等用）。
  Iterable<FavNode> get folders => _folderNodes;
  Iterable<FavNode> get projects => _projectNodes;

  /// [folderId] 下（含子孙文件夹）的全部工程 cid（文件夹级显隐联动用）。
  List<String> projectCidsUnder(String folderId) {
    final folderIds = _descendantFolderIds(folderId)..add(folderId);
    return [
      for (final p in _projectNodes)
        if (folderIds.contains(p.pid)) p.id,
    ];
  }

  /// 公开版成环检查（拖拽预检用）。
  bool wouldCycle(String fid, String parentId) => _wouldCycle(fid, parentId);

  /// 对外触发一次树刷新通知（首帧可见性对齐等"只改内存"的场景用）。
  void notifyTreeChanged() => notifyListeners();

  late final Future<void> _ready;

  /// 构造后触发的异步初始化（读可见性 + 建树）完成信号；测试与 UI 可 await。
  Future<void> get ready => _ready;

  Future<void> _init() async {
    await _loadVisibility();
    _rebuild();
    notifyListeners();
  }

  // ---------- 树骨架（folder / project，内存） ----------

  final List<FavNode> _folderNodes = [];
  final List<FavNode> _projectNodes = [];
  final Map<String, FavNode> _index = {};

  /// 树根节点：顶层文件夹 + 根目录工程（folder 悬空时兜底为根）。
  List<FavNode> roots = const [];

  /// 点位真相源缓存：cid → labels。
  /// 只走 `store.loadCollection`，与 overlayLabels（地图渲染层）完全隔离。
  final Map<String, List<MapLabel>> _labelCache = {};

  void _onAppState() {
    // 点位真相源只认磁盘：updateLabel/removeLabel 等只 notify 不 refresh，
    // 任何 AppState 变化都可能伴随 collection 文件写入，因此点位缓存全部失效，
    // 下次 childrenOf/countOf 按需重读；骨架重建不迁移旧 children（防过期）。
    _labelCache.clear();
    _rebuild();
    notifyListeners();
  }

  @override
  void dispose() {
    _st.removeListener(_onAppState);
    super.dispose();
  }

  /// 重建 folder/project 骨架。
  ///
  /// 只建内存骨架；project/chain 的子节点永远懒加载（childrenOf），
  /// 不做旧 children 迁移——磁盘是唯一真相源，迁移会带来过期数据。
  void _rebuild() {
    _index.clear();
    _folderNodes.clear();
    _projectNodes.clear();

    for (final f in _st.folders) {
      if (f.id.isEmpty) continue; // 跳过 loadFolders() 的"默认"伪根
      _folderNodes.add(FavNode.folderNode(f));
    }
    for (final m in _st.collections) {
      _projectNodes.add(FavNode.projectNode(m));
    }

    for (final p in _projectNodes) {
      _index[p.id] = p;
    }
    for (final f in _folderNodes) {
      _index[f.id] = f;
    }
    // 点位缓存：工程已不存在则丢弃。
    _labelCache.removeWhere((cid, _) => !_index.containsKey(cid));

    final folderIds = {for (final f in _folderNodes) f.id};
    roots = [
      for (final f in _folderNodes)
        if (f.pid.isEmpty) f,
      for (final p in _projectNodes)
        if (p.pid.isEmpty || !folderIds.contains(p.pid)) p,
    ];
  }

  /// 点位懒加载（真相源；overlayLabels 绝不参与）。
  Future<List<MapLabel>> _labelsOf(String cid) async {
    var hit = _labelCache[cid];
    if (hit == null) {
      hit = await _store.loadCollection(cid);
      _labelCache[cid] = hit;
    }
    return hit;
  }

  // ---------- 树查询 ----------

  FavNode? find(String id) => _index[id];

  /// 从根到该节点的路径（含自身）；id 不存在或成环时返回已走部分。
  List<FavNode> pathOf(String id) {
    final path = <FavNode>[];
    var cur = _index[id];
    final seen = <String>{};
    while (cur != null && seen.add(cur.id)) {
      path.insert(0, cur);
      if (cur.pid.isEmpty) break;
      cur = _index[cur.pid];
    }
    return path;
  }

  /// 取某节点的子节点（懒加载）。
  /// - folder：子文件夹 + 工程（内存骨架）。
  /// - project：mark / chain 虚拟节点（首次走磁盘懒加载）。
  /// - chain：成员 mark 节点。
  /// - mark：空。
  Future<List<FavNode>> childrenOf(String pid) async {
    var node = _index[pid];
    if (node == null) return const [];
    switch (node.kind) {
      case FavKind.folder:
        return [
          for (final f in _folderNodes)
            if (f.pid == pid) f,
          for (final p in _projectNodes)
            if (p.pid == pid) p,
        ];
      case FavKind.project:
        if (node.children != null) return node.children!;
        final labels = await _labelsOf(pid);
        final kids = _buildProjectKids(node, labels);
        // await 期间树可能已重建：挂到当前索引中的节点上。
        node = _index[pid];
        if (node == null || !node.isProject) return kids;
        node.children = kids;
        for (final k in kids) {
          _index[k.id] = k;
          if (k.isChain) {
            k.children = _buildChainMembers(k);
            for (final m in k.children!) {
              _index[m.id] = m;
            }
          }
        }
        return kids;
      case FavKind.chain:
        return node.children ?? const [];
      case FavKind.mark:
        return const [];
    }
  }

  List<FavNode> _buildProjectKids(FavNode project, List<MapLabel> labels) {
    final chains = buildLabelChains(labels);
    final inChain = <String>{
      for (final c in chains)
        for (final l in c) l.id
    };
    final kids = <FavNode>[];
    for (final c in chains) {
      kids.add(FavNode.chainNode(
        cid: project.id,
        groupId: c.first.lineGroupId,
        pid: project.id,
        pointCount: c.length,
      ));
    }
    for (final l in labels) {
      if (inChain.contains(l.id)) continue;
      kids.add(FavNode.markNode(l, pid: project.id, cid: project.id));
    }
    return kids;
  }

  List<FavNode> _buildChainMembers(FavNode chain) {
    final labels = _labelCache[chain.chainCid] ?? const <MapLabel>[];
    final gid = chain.chainGroupId;
    return [
      for (final l in labels)
        if (l.lineGroupId == gid && isLineMember(l))
          FavNode.markNode(l, pid: chain.id, cid: chain.chainCid!),
    ];
  }

  // ---------- 计数（含标记；审计问题 10） ----------

  /// 统计文件夹（含子孙文件夹）下全部条目数：
  /// 工程数 + 各工程内点数（mark 与 chain 成员）。
  ///
  /// 必须 async：未展开工程的点数要走磁盘读。
  Future<int> countOf(String folderId) async {
    final folderIds = _descendantFolderIds(folderId)..add(folderId);
    var n = 0;
    for (final p in _projectNodes) {
      if (!folderIds.contains(p.pid)) continue;
      n += 1; // 工程本身
      n += (await _labelsOf(p.id)).length;
    }
    return n;
  }

  Set<String> _descendantFolderIds(String fid) {
    final out = <String>{};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in _folderNodes) {
        if (f.id != fid &&
            !out.contains(f.id) &&
            (f.pid == fid || out.contains(f.pid))) {
          out.add(f.id);
          grew = true;
        }
      }
    }
    return out;
  }

  // ---------- 多选 ----------

  /// 多选集（节点 id）。桌面 Shift/Ctrl + 移动端长按多选模式共用。
  final Set<String> selected = {};

  void toggleSelect(String id) {
    if (!selected.remove(id)) selected.add(id);
    notifyListeners();
  }

  void selectOnly(String id) {
    selected
      ..clear()
      ..add(id);
    notifyListeners();
  }

  void selectAll(Iterable<String> ids) {
    selected.addAll(ids);
    notifyListeners();
  }

  void clearSelection() {
    if (selected.isEmpty) return;
    selected.clear();
    notifyListeners();
  }

  // ---------- 树选中层（独立于 AppState.folderId；审计问题 9） ----------

  /// 树当前选中层（'' = 根）。绝不读写 AppState.folderId（草稿保存目标层）。
  String treeSelectedFolderId = '';

  void selectTreeFolder(String folderId) {
    if (treeSelectedFolderId == folderId) return;
    treeSelectedFolderId = folderId;
    notifyListeners();
  }

  // ---------- 可见性 ----------

  /// 隐藏的节点 id（内存）。读 index.json 可选字段 `visible` 恢复（缺省 true）。
  /// 只有 project 落盘；folder / mark 的显隐目前仅内存态（Phase 2 定 UI 语义）。
  final Set<String> hiddenIds = {};

  bool isVisible(String id) => !hiddenIds.contains(id);

  Future<void> setVisible(String id, bool visible) async {
    final changed = visible ? hiddenIds.remove(id) : hiddenIds.add(id);
    if (!changed) return;
    notifyListeners();
    final node = _index[id];
    if (node != null && node.isProject) {
      await _persistProjectVisible(id, visible);
    }
  }

  Future<void> _loadVisibility() async {
    try {
      final dir = await _store.labelsDir();
      final f = File('${dir.path}/index.json');
      if (!f.existsSync()) return;
      final decoded = jsonDecode(await f.readAsString());
      final List items = decoded is List
          ? decoded
          : ((decoded as Map)['items'] as List? ?? []);
      for (final e in items) {
        final m = (e as Map).cast<String, dynamic>();
        final id = m['id'];
        if (id is String && m['visible'] == false) hiddenIds.add(id);
      }
    } catch (_) {}
  }

  /// 把 project 的可见性以可选字段 `visible` 写回 index.json。
  /// 纯加法：只动该字段，其余键原样保留；visible=true 时删掉该键保持文件干净。
  /// 不经过 store.dart（红线：不改其磁盘格式逻辑），此处自包含读写。
  Future<void> _persistProjectVisible(String cid, bool visible) async {
    try {
      final dir = await _store.labelsDir();
      final f = File('${dir.path}/index.json');
      if (!f.existsSync()) return;
      final decoded = jsonDecode((await f.readAsString()).trim());
      final List<Map<String, dynamic>> items;
      if (decoded is List) {
        items = decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } else {
        items = (((decoded as Map)['items'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      var touched = false;
      for (final m in items) {
        if (m['id'] == cid) {
          if (visible) {
            m.remove('visible');
          } else {
            m['visible'] = false;
          }
          touched = true;
          break;
        }
      }
      if (!touched) return;
      await robustWriteAsString(f, jsonEncode({'items': items}));
    } catch (_) {}
  }

  // ---------- 移动操作（全部走现有 store/AppState 方法，不造新格式） ----------

  /// 把节点移入目标文件夹（'' = 根）。
  /// - folder → `store.setFolderParent`（成环移动返回 false，不落盘）
  /// - project → `store.moveCollection`
  /// - mark → 目标文件夹的"标记"工程（没有自动建；复用 AppState.moveMarkToFolder）
  /// - chain → 整条链的点一起移入目标文件夹的"标记"工程
  Future<bool> moveToFolder(FavNode node, String folderId) async {
    switch (node.kind) {
      case FavKind.folder:
        if (_wouldCycle(node.id, folderId)) return false;
        await _store.setFolderParent(node.id, folderId);
        await _st.refreshCollections();
        return true;
      case FavKind.project:
        await _store.moveCollection(node.id, folderId);
        await _st.refreshCollections();
        return true;
      case FavKind.mark:
        final fromCid = node.labelCid;
        final labelId = node.label?.id;
        if (fromCid == null || labelId == null) return false;
        final labels = await _labelsOf(fromCid);
        final hit = labels.where((e) => e.id == labelId).toList();
        if (hit.isEmpty) return false;
        await _st.moveMarkToFolder(fromCid, hit.first, folderId);
        return true;
      case FavKind.chain:
        final fromCid = node.chainCid;
        if (fromCid == null) return false;
        final members = await childrenOf(node.id);
        if (members.isEmpty) return true;
        for (final m in members) {
          final labelId = m.label?.id;
          if (labelId == null) continue;
          // 每轮重读磁盘：上一轮搬移已改变源文件内容。
          final fresh = await _store.loadCollection(fromCid);
          final hit = fresh.where((e) => e.id == labelId).toList();
          if (hit.isEmpty) continue;
          await _st.moveMarkToFolder(fromCid, hit.first, folderId);
        }
        return true;
    }
  }

  /// 跨工程移动单个标记。fromCid == toCid / 找不到时返回 false。
  Future<bool> moveMarkToProject(
      String labelId, String fromCid, String toCid) async {
    if (fromCid == toCid) return false;
    if (!_index.containsKey(toCid)) return false;
    final labels = await _labelsOf(fromCid);
    final hit = labels.where((e) => e.id == labelId).toList();
    if (hit.isEmpty) return false;
    await _st.moveLabelToProject(
        fromCid: fromCid, label: hit.first, toCid: toCid);
    return true;
  }

  /// 合并工程：fromCid 的点全部追加到 toCid，随后删除 fromCid。
  /// 返回搬移点数。确认框由调用方（UI）负责。
  Future<int> mergeProject(String fromCid, String toCid) async {
    if (fromCid == toCid) return 0;
    final toMeta =
        _st.collections.where((m) => m.id == toCid).toList();
    if (toMeta.isEmpty) return 0;
    final fromLabels = await _store.loadCollection(fromCid);
    if (fromLabels.isNotEmpty) {
      final toLabels = await _store.loadCollection(toCid);
      for (final l in fromLabels) {
        l.seq = toLabels.length + 1;
        toLabels.add(l);
      }
      final meta = toMeta.first;
      await _store.finishCollection(
        existingId: toCid,
        name: meta.name,
        kind: meta.kind,
        folderId: meta.folder,
        editMode: meta.editMode,
        labels: toLabels,
      );
    }
    await _store.deleteCollection(fromCid);
    await _st.refreshCollections();
    return fromLabels.length;
  }

  /// 把 fid 移入 parentId 是否会成环（自己 / 自己的后代）。
  bool _wouldCycle(String fid, String parentId) {
    if (fid == parentId) return true;
    final byId = {for (final f in _folderNodes) f.id: f};
    var p = parentId;
    final seen = <String>{};
    while (p.isNotEmpty && seen.add(p)) {
      if (p == fid) return true;
      p = byId[p]?.pid ?? '';
    }
    return false;
  }
}
