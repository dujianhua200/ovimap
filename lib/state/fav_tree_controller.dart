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

  /// 索引中的全部节点 id（含已懒加载的子节点）：Ctrl+A 全选的口径。
  Iterable<String> get allIndexedIds => _index.keys;

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
    hiddenIds
      ..clear()
      ..addAll(await loadIndexHiddenIds(_store));
  }

  /// 读 index.json 里 `visible == false` 的 id 集合（纯函数，无副作用）。
  ///
  /// D3 双源统一：[AppState.init] 与 [_loadVisibility] 共用——index.json 是
  /// 较新的写入机制（`visible` 可选字段），跨端/持久化补充，init 时优先剔除。
  static Future<Set<String>> loadIndexHiddenIds(LabelStore store) async {
    final out = <String>{};
    try {
      final dir = await store.labelsDir();
      final f = File('${dir.path}/index.json');
      if (!f.existsSync()) return out;
      final decoded = jsonDecode(await f.readAsString());
      final List items = decoded is List
          ? decoded
          : ((decoded as Map)['items'] as List? ?? []);
      for (final e in items) {
        final m = (e as Map).cast<String, dynamic>();
        final id = m['id'];
        if (id is String && m['visible'] == false) out.add(id);
      }
    } catch (_) {}
    return out;
  }

  /// 把 project 的可见性以可选字段 `visible` 写回 index.json。
  /// 纯加法：只动该字段，其余键原样保留；visible=true 时删掉该键保持文件干净。
  /// 不经过 store.dart（红线：不改其磁盘格式逻辑），此处自包含读写。
  ///
  /// public static：D3 双源统一——[AppState.toggleVisible]/[AppState.setVisibleBulk]
  /// 写 prefs 的同时经此双写 index.json（同一份逻辑，不复制）。
  static Future<void> persistProjectVisible(
      LabelStore store, String cid, bool visible) async {
    try {
      final dir = await store.labelsDir();
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

  Future<void> _persistProjectVisible(String cid, bool visible) =>
      persistProjectVisible(_store, cid, visible);

  // ---------- 移动操作（全部走现有 store/AppState 方法，不造新格式） ----------
  //
  // 记录约定（W1 全局撤销）：public 方法是 undoable 入口，用
  // `_st.undoStack.execute` 包裹；`_xxxRaw` 是底层实现，保持 raw、
  // 自身不记录——调用方只调 public 方法，防双重记录。

  /// 把节点移入目标文件夹（'' = 根），可撤销。
  /// - folder → 逆操作 = setFolderParent 回原 parent（成环检查已在 raw 内）
  /// - project → 逆操作 = moveCollection 回原 folder
  /// - mark/chain → do 经 _st.moveMarkToFolder 搬入目标文件夹的「标记」工程；
  ///   逆操作 = 用 moveLabelToProject 把点搬回原工程（目标 cid 在 do 后
  ///   解析：目标文件夹下 kind=='mark' 的工程；解析不到则 undo 返回 false
  ///   不抛错）
  Future<bool> moveToFolder(FavNode node, String folderId) async {
    switch (node.kind) {
      case FavKind.folder: {
        final oldParent = node.pid;
        if (oldParent == folderId) return true;
        var ok = false;
        await _st.undoStack.execute(
          '移动文件夹「${node.name}」',
          () async {
            ok = await _moveToFolderRaw(node, folderId);
            return ok;
          },
          () async {
            await _store.setFolderParent(node.id, oldParent);
            await _st.refreshCollections();
            return true;
          },
        );
        return ok;
      }
      case FavKind.project: {
        final oldFolder = node.pid;
        if (oldFolder == folderId) return true;
        var ok = false;
        await _st.undoStack.execute(
          '移动工程「${node.name}」',
          () async {
            ok = await _moveToFolderRaw(node, folderId);
            return ok;
          },
          () async {
            await _store.moveCollection(node.id, oldFolder);
            await _st.refreshCollections();
            return true;
          },
        );
        return ok;
      }
      case FavKind.mark: {
        final fromCid = node.labelCid;
        final labelId = node.label?.id;
        if (fromCid == null || labelId == null) return false;
        var ok = false;
        await _st.undoStack.execute(
          '移动标记「${node.name}」',
          () async {
            ok = await _moveToFolderRaw(node, folderId);
            return ok;
          },
          () async => _moveMarkBackToProject(
              labelId: labelId, fromCid: fromCid, folderId: folderId),
        );
        return ok;
      }
      case FavKind.chain: {
        final fromCid = node.chainCid;
        if (fromCid == null) return false;
        final members = await childrenOf(node.id);
        final labelIds = [
          for (final m in members)
            if (m.isMark && m.label?.id != null) m.label!.id,
        ];
        if (labelIds.isEmpty) return true;
        var ok = false;
        await _st.undoStack.execute(
          '移动线组「${node.name}」',
          () async {
            ok = await _moveToFolderRaw(node, folderId);
            return ok;
          },
          () async {
            var moved = 0;
            for (final lid in labelIds) {
              if (await _moveMarkBackToProject(
                  labelId: lid, fromCid: fromCid, folderId: folderId)) {
                moved++;
              }
            }
            return moved > 0;
          },
        );
        return ok;
      }
    }
  }

  /// 把点从目标文件夹的「标记」工程搬回原工程（mark/chain 文件夹移动的逆操作）。
  ///
  /// 判定口径与 [AppState.moveMarkToFolder] 的目标解析一致
  /// （kind=='mark' 或名为「标记」；取 folders 顺序第一个）。目标工程在
  /// do 后解析；解析不到（如用户已删该工程）或点不在其中时返回 false，
  /// 不抛错。
  Future<bool> _moveMarkBackToProject({
    required String labelId,
    required String fromCid,
    required String folderId,
  }) async {
    String? targetCid;
    for (final m in _st.collections) {
      if ((m.kind == 'mark' || m.name == AppState.kMarkBook) &&
          m.folder == folderId) {
        targetCid = m.id;
        break;
      }
    }
    if (targetCid == null) return false;
    final labels = await _labelsOf(targetCid);
    final hit = labels.where((e) => e.id == labelId).toList();
    if (hit.isEmpty) return false;
    await _st.moveLabelToProject(
        fromCid: targetCid, label: hit.first, toCid: fromCid);
    return true;
  }

  /// 底层移动实现（raw：自身不记录撤销，由 public 包裹）。
  Future<bool> _moveToFolderRaw(FavNode node, String folderId) async {
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

  /// 跨工程移动单个标记（可撤销）。fromCid == toCid / 找不到时返回 false。
  ///
  /// 逆操作 = 把点从 toCid 移回 fromCid（经 AppState.moveLabelToProject，
  /// raw，不再记录）。
  Future<bool> moveMarkToProject(
      String labelId, String fromCid, String toCid) async {
    if (fromCid == toCid) return false;
    if (!_index.containsKey(toCid)) return false;
    var ok = false;
    await _st.undoStack.execute(
      '移动标记到工程「${_index[toCid]?.name ?? ''}」',
      () async {
        ok = await _moveMarkToProjectRaw(labelId, fromCid, toCid);
        return ok;
      },
      () async {
        final labels = await _labelsOf(toCid);
        final hit = labels.where((e) => e.id == labelId).toList();
        if (hit.isEmpty) return false;
        await _st.moveLabelToProject(
            fromCid: toCid, label: hit.first, toCid: fromCid);
        return true;
      },
    );
    return ok;
  }

  /// 底层跨工程移动实现（raw：自身不记录撤销，由 public 包裹）。
  Future<bool> _moveMarkToProjectRaw(
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

  /// 合并工程（可撤销）：fromCid 的点全部追加到 toCid，随后删除 fromCid。
  /// 返回搬移点数。确认框由调用方（UI）负责。
  ///
  /// 唯一允许全量快照的场景：undo 需要"从 toCid 按 id 剔除本次并入的点 +
  /// 用原 meta（含样式/描述）重建已被删除的 fromCid"，反向操作无法用
  /// 最小数据表达，因此 do 前快照 fromLabels / toLabels 的 JSON +
  /// fromMeta。toCid 用 id 剔除而非快照回写：保留用户在合并后对 toCid
  /// 的其它编辑；toLabels 快照仅作一致性存档。
  ///
  /// redo = 重新执行合并（UndoStack.redo 会再次调用 doIt）。
  Future<int> mergeProject(String fromCid, String toCid) async {
    if (fromCid == toCid) return 0;
    final fromMetaList =
        _st.collections.where((m) => m.id == fromCid).toList();
    final toMetaList = _st.collections.where((m) => m.id == toCid).toList();
    if (fromMetaList.isEmpty || toMetaList.isEmpty) return 0;
    final fromMetaJson = jsonEncode(fromMetaList.first.toJson());
    final fromLabelsJson = jsonEncode((await _store.loadCollection(fromCid))
        .map((e) => e.toJson())
        .toList());
    final toLabelsJson = jsonEncode((await _store.loadCollection(toCid))
        .map((e) => e.toJson())
        .toList());
    var moved = 0;
    final ok = await _st.undoStack.execute(
      '合并工程「${fromMetaList.first.name}」到「${toMetaList.first.name}」',
      () async {
        moved = await _mergeProjectRaw(fromCid, toCid);
        return moved >= 0;
      },
      () async => _unmergeProjectRaw(
        fromCid: fromCid,
        toCid: toCid,
        fromMetaJson: fromMetaJson,
        fromLabelsJson: fromLabelsJson,
        toLabelsJson: toLabelsJson,
      ),
    );
    return ok ? moved : 0;
  }

  /// 底层合并实现（raw：自身不记录撤销，由 public 包裹）。
  /// 返回搬移点数；非法参数返回 -1。
  Future<int> _mergeProjectRaw(String fromCid, String toCid) async {
    if (fromCid == toCid) return -1;
    final toMeta = _st.collections.where((m) => m.id == toCid).toList();
    if (toMeta.isEmpty) return -1;
    final fromLabels = await _store.loadCollection(fromCid);
    if (fromLabels.isNotEmpty) {
      final toLabels = await _store.loadCollection(toCid);
      for (final l in fromLabels) {
        l.seq = toLabels.length + 1;
        toLabels.add(l);
      }
      // 用 meta 保留式写回：finishCollection 会丢 color/width/desc，
      // 合并不应改变目标工程样式。
      await _writeCollectionWithMeta(toMeta.first, toLabels);
    }
    await _store.deleteCollection(fromCid);
    await _st.refreshCollections();
    return fromLabels.length;
  }

  /// 合并的逆操作（raw）：从 toCid 剔除本次并入的点（按 id 集合），再用
  /// 快照重建 fromCid（含原 meta：名称/类型/文件夹/样式/描述）。
  Future<bool> _unmergeProjectRaw({
    required String fromCid,
    required String toCid,
    required String fromMetaJson,
    required String fromLabelsJson,
    required String toLabelsJson,
  }) async {
    final fromLabels = (jsonDecode(fromLabelsJson) as List)
        .map((e) =>
            MapLabel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final mergedIds = {for (final l in fromLabels) l.id};
    // 1. 从 toCid 剔除本次并入的点（按 id；保留用户合并后对 toCid 的编辑）。
    //    toLabelsJson 仅作存档：若 toCid 已被用户删除，不复活（不写回）。
    final toMetaList = _st.collections.where((m) => m.id == toCid).toList();
    if (toMetaList.isNotEmpty) {
      final toLabels = await _store.loadCollection(toCid);
      toLabels.removeWhere((e) => mergedIds.contains(e.id));
      await _writeCollectionWithMeta(toMetaList.first, toLabels);
    }
    // 2. 用快照重建 fromCid（含原 meta）。
    final fromMeta = CollectionMeta.fromJson(
        Map<String, dynamic>.from(jsonDecode(fromMetaJson) as Map));
    await _writeCollectionWithMeta(fromMeta, fromLabels);
    await _st.refreshCollections();
    return true;
  }

  /// 按给定 meta + labels 写回工程（collection 文件 + index 条目），保留
  /// color/width/desc 等全部元字段。不用 `finishCollection`（它重建索引
  /// 条目时会丢样式字段）。镜像 trash.dart 的 _restoreProject，不动
  /// store.dart。
  Future<void> _writeCollectionWithMeta(
      CollectionMeta meta, List<MapLabel> labels) async {
    final dir = await _store.labelsDir();
    final body = <String, dynamic>{
      'id': meta.id,
      'name': meta.name,
      'kind': meta.kind,
      'createdAt': meta.createdAt == 0
          ? DateTime.now().millisecondsSinceEpoch
          : meta.createdAt,
      'finished': true,
      'folderId': meta.folder,
      'editMode': meta.editMode,
      'labels': labels.map((l) => l.toJson()).toList(),
    };
    await robustWriteAsString(
        File('${dir.path}/collection_${meta.id}.json'), jsonEncode(body));
    final items = await _loadIndexItemsRaw();
    final entry = meta.toJson();
    entry['count'] = labels.length;
    final out = [
      for (final e in items)
        if (e['id'] != meta.id) e,
      entry,
    ];
    await robustWriteAsString(
        File('${dir.path}/index.json'), jsonEncode({'items': out}));
  }

  /// 镜像 store._loadIndexItems（读 index.json 原文条目；不动 store.dart）。
  Future<List<Map<String, dynamic>>> _loadIndexItemsRaw() async {
    try {
      final dir = await _store.labelsDir();
      final f = File('${dir.path}/index.json');
      if (!f.existsSync()) return [];
      final decoded = jsonDecode((await f.readAsString()).trim());
      if (decoded is List) {
        return decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      final items = (decoded as Map)['items'];
      if (items is! List) return [];
      return items.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  // ---------- 重命名 / 新建 / 改样式（undoable 包裹；调用方原直接调 store） ----------
  //
  // 调用点原在 UI 层（tree_menus.dart、select_bar.dart）直接调
  // store.renameFolder / renameCollection / setCollectionStyle /
  // addFolder，现改调以下包裹方法；不改 store.dart。

  String? _folderNameOf(String fid) {
    for (final f in _st.folders) {
      if (f.id == fid) return f.name;
    }
    return null;
  }

  /// 文件夹重命名（可撤销）。
  Future<bool> renameFolderUndoable(String fid, String newName) async {
    final oldName = _folderNameOf(fid);
    if (oldName == null) return false;
    if (oldName == newName) return true;
    var ok = false;
    await _st.undoStack.execute(
      '重命名文件夹「$oldName」',
      () async {
        await _store.renameFolder(fid, newName);
        await _st.refreshCollections();
        ok = true;
        return true;
      },
      () async {
        await _store.renameFolder(fid, oldName);
        await _st.refreshCollections();
        return true;
      },
    );
    return ok;
  }

  /// 工程重命名（可撤销）。
  Future<bool> renameCollectionUndoable(String cid, String newName) async {
    final metas = _st.collections.where((m) => m.id == cid).toList();
    if (metas.isEmpty) return false;
    final oldName = metas.first.name;
    if (oldName == newName) return true;
    var ok = false;
    await _st.undoStack.execute(
      '重命名工程「$oldName」',
      () async {
        await _store.renameCollection(cid, newName);
        await _st.refreshCollections();
        ok = true;
        return true;
      },
      () async {
        await _store.renameCollection(cid, oldName);
        await _st.refreshCollections();
        return true;
      },
    );
    return ok;
  }

  /// 工程改样式（可撤销）。undo 恢复旧 color/width。
  Future<bool> setCollectionStyleUndoable(
      String cid, int color, double width) async {
    final metas = _st.collections.where((m) => m.id == cid).toList();
    if (metas.isEmpty) return false;
    final oldColor = metas.first.color;
    final oldWidth = metas.first.width;
    if (oldColor == color && oldWidth == width) return true;
    var ok = false;
    await _st.undoStack.execute(
      '修改工程「${metas.first.name}」样式',
      () async {
        await _store.setCollectionStyle(cid, color, width);
        await _st.refreshCollections();
        ok = true;
        return true;
      },
      () async {
        await _store.setCollectionStyle(cid, oldColor, oldWidth);
        await _st.refreshCollections();
        return true;
      },
    );
    return ok;
  }

  /// 新建文件夹（可撤销）：undo = 删除新建的文件夹（新建时必为空，无级联）。
  /// 返回新建文件夹 id；失败返回 null。
  Future<String?> addFolderUndoable(String name, [String parentId = '']) async {
    String? newId;
    await _st.undoStack.execute(
      '新建文件夹「$name」',
      () async {
        final f = await _store.addFolder(name, parentId);
        newId = f.id;
        await _st.refreshCollections();
        return true;
      },
      () async {
        final id = newId;
        if (id == null) return false;
        await _store.deleteFolder(id);
        await _st.refreshCollections();
        return true;
      },
    );
    return newId;
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
