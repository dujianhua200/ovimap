import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/fav_node.dart';
import '../../services/platform_caps.dart';
import '../../state/fav_tree_controller.dart';
import '../design_tokens.dart';
import '../dialogs.dart';
import 'fav_actions.dart';
import 'tree_drag.dart';
import 'tree_menus.dart';

/// 收藏树共享组件（桌面/移动共用；移动线直接消费）。
///
/// 构造函数签名冻结（只允许加法）：
/// - [controller] Phase 1 统一控制器（唯一数据源；点位真相源只走它，
///   不碰 `AppState.overlayLabels`）；
/// - [compact] false = 桌面行高 32，true = 移动行高 48；
/// - [onLocate] 点位定位（总是收到带 [FavNode.label] 的 mark 节点；
///   工程/线组定位时内部取其首个点位包装成 mark 节点）；
/// - [onOpenProject] 工程行点击 → 打开工程；
/// - [query]（加法）搜索关键词；非空时进入搜索模式：结果列表之上保留
///   文件夹投放行（审计问题 3）；
/// - [projectTrailing]（加法）工程行右侧附加组件（桌面：同步徽标 + ⋮ 菜单）；
/// - [menuExtra]（加法）节点菜单的追加项（桌面：「把当前画布收藏到此」；
///   移动：`favMobileProjectExtra()` 的 7 个工程操作）。
///
/// 平台差异（`PlatformCaps.isDesktop` 分支）：
/// - 拖拽：桌面行用 [Draggable]（鼠标即拖）；移动端用 [LongPressDraggable]，
///   行上竖滑留给滚动（P0）；
/// - compact（移动）模式：所有行尾都有「⋯」→ [showFavNodeMenu]（移动端底弹样式），
///   文件夹/mark/chain 行不再没有菜单入口；
/// - 多选：移动端长按进入多选；多选非空时点选 = 切换选中（toggle）。
class FavTree extends StatefulWidget {
  const FavTree({
    super.key,
    required this.controller,
    this.compact = false,
    this.onLocate,
    this.onOpenProject,
    this.query = '',
    this.projectTrailing,
    this.menuExtra,
  });

  final FavTreeController controller;
  final bool compact;
  final Future<void> Function(FavNode)? onLocate;
  final void Function(FavNode)? onOpenProject;
  final String query;
  final Widget Function(BuildContext context, FavNode node)? projectTrailing;
  final FavMenuExtra? menuExtra;

  @override
  State<FavTree> createState() => _FavTreeState();
}

/// 树内回调作用域：右键/长按菜单（[showFavNodeMenu]）通过它拿到定位回调。
class FavTreeScope extends InheritedWidget {
  const FavTreeScope({
    super.key,
    required this.onLocate,
    required this.onOpenProject,
    required super.child,
  });

  final Future<void> Function(FavNode)? onLocate;
  final void Function(FavNode)? onOpenProject;

  static FavTreeScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FavTreeScope>();

  @override
  bool updateShouldNotify(FavTreeScope old) =>
      old.onLocate != onLocate || old.onOpenProject != onOpenProject;
}

/// 搜索命中：节点 + 从根到该节点的路径（含自身）。
class FavSearchHit {
  final FavNode node;
  final List<FavNode> path;
  const FavSearchHit(this.node, this.path);
}

/// 文件夹的可见子节点：`kind=='mark'` 的伪工程**不渲染为行**，
/// 将其 marks 内联平铺在父文件夹下（保持现有桌面行为）。
Future<List<FavNode>> visibleChildrenOf(
    FavTreeController c, FavNode parent) async {
  final kids = await c.childrenOf(parent.id);
  final out = <FavNode>[];
  for (final k in kids) {
    if (k.isProject && (k.project?.kind == 'mark' || k.name == '标记')) {
      out.addAll(await c.childrenOf(k.id));
    } else {
      out.add(k);
    }
  }
  return out;
}

bool _markMatches(FavNode m, String q) {
  if (m.name.toLowerCase().contains(q)) return true;
  final note = m.label?.note ?? '';
  return note.isNotEmpty && note.toLowerCase().contains(q);
}

/// 按名称/备注搜索 folder + project + mark（含未展开工程的 labels，
/// 走 controller 缓存即 `_labelsOf` 语义，不自己读文件）。
Future<List<FavSearchHit>> searchFavTree(
    FavTreeController c, String keyword) async {
  final q = keyword.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final hits = <FavSearchHit>[];
  for (final f in c.folders) {
    if (f.name.toLowerCase().contains(q)) {
      hits.add(FavSearchHit(f, c.pathOf(f.id)));
    }
  }
  for (final p in c.projects) {
    final nameHit = p.name.toLowerCase().contains(q);
    final descHit = (p.project?.desc ?? '').toLowerCase().contains(q);
    if (nameHit || descHit) hits.add(FavSearchHit(p, c.pathOf(p.id)));
    for (final k in await c.childrenOf(p.id)) {
      if (k.isChain) {
        for (final m in await c.childrenOf(k.id)) {
          if (m.isMark && _markMatches(m, q)) {
            hits.add(FavSearchHit(m, [...c.pathOf(p.id), k]));
          }
        }
      } else if (k.isMark && _markMatches(k, q)) {
        hits.add(FavSearchHit(k, c.pathOf(p.id)));
      }
    }
  }
  return hits;
}

/// 工程类型 tag（桌面 _itemCard 口径，收敛到共享处）。
String favKindTag(FavNode node) {
  final m = node.project;
  if (m == null) return '';
  if (m.kind == 'mark') return '标记';
  if (m.kind == 'track') return '轨迹';
  if (m.kind == 'data') return '数据';
  return m.editMode == 'completion' ? '竣工' : '设计';
}

/// 工程类型 tag 颜色（桌面 _itemCard 口径）。
Color favKindColor(FavNode node) {
  final m = node.project;
  if (m == null) return kTextSub;
  if (m.kind == 'mark') return const Color(0xFFE6A23C);
  if (m.editMode == 'completion') return TokC.warn;
  if (m.kind == 'track') return const Color(0xFFFFD54F);
  return const Color(0xFF81C784);
}

class _FavTreeState extends State<FavTree> {
  FavTreeController get c => widget.controller;

  /// 手动收起的节点 id；未记录 = 展开（新建文件夹天然展开）。
  final Set<String> _collapsed = <String>{};
  final ScrollController _scroll = ScrollController();

  final Map<String, Future<List<FavNode>>> _kidsFutures = {};
  final Map<String, Future<int>> _counts = {};

  /// 当前可见行顺序（Shift 范围选 / 全选用）。
  final List<String> _order = [];
  String _anchor = '';

  String _activeQuery = '';
  Future<List<FavSearchHit>>? _searchFuture;
  Timer? _debounce;
  List<FavNode>? _lastRoots;

  @override
  void initState() {
    super.initState();
    _lastRoots = widget.controller.roots;
    _activeQuery = widget.query;
    if (_activeQuery.isNotEmpty) {
      _searchFuture = searchFavTree(c, _activeQuery);
    }
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(FavTree old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastRoots = widget.controller.roots;
      _kidsFutures.clear();
      _counts.clear();
    }
    if (old.query != widget.query) {
      _debounce?.cancel();
      final q = widget.query;
      if (q.isEmpty) {
        _activeQuery = '';
        _searchFuture = null;
        setState(() {});
      } else {
        // 轻微防抖：每敲一个字都读全库文件太伤。
        _debounce = Timer(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          setState(() {
            _activeQuery = q;
            _searchFuture = searchFavTree(c, q);
          });
        });
      }
    }
  }

  /// 结构变化（roots 换实例）时清 children/count 缓存；
  /// 纯选择/显隐变化不清理，避免反复读盘。
  void _onControllerChanged() {
    if (!identical(_lastRoots, widget.controller.roots)) {
      _lastRoots = widget.controller.roots;
      _kidsFutures.clear();
      _counts.clear();
      _searchFuture =
          _activeQuery.isEmpty ? null : searchFavTree(c, _activeQuery);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  double get _rowH => widget.compact ? 48.0 : 32.0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        _order.clear();
        final body =
            _activeQuery.isEmpty ? _buildTree() : _buildSearch();
        return FavTreeScope(
          onLocate: widget.onLocate,
          onOpenProject: widget.onOpenProject,
          child: FavAutoScroller(
            scrollController: _scroll,
            child: body,
          ),
        );
      },
    );
  }

  // ---------- 树体 ----------

  Widget _buildTree() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _rootRow(),
        for (final r in c.roots) _nodeRow(r, 1),
      ],
    );
  }

  /// 根行「收藏夹」：整行可投放（'' = 根）。
  Widget _rootRow() {
    _order.add('');
    final selected = c.treeSelectedFolderId.isEmpty;
    Widget row = InkWell(
      onTap: () {
        c.selectTreeFolder('');
        if (c.selected.isNotEmpty) c.clearSelection();
      },
      child: Container(
        height: _rowH,
        padding: const EdgeInsets.only(left: 8, right: 4),
        color: selected ? kAccent.withValues(alpha: 0.14) : null,
        child: Row(children: [
          const Icon(Icons.bookmarks, size: 16, color: kAccent),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('收藏夹',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: kTextMain,
                    fontSize: TokFs.body,
                    fontWeight: FontWeight.w600)),
          ),
          FutureBuilder<int>(
            future: _counts.putIfAbsent('::root', () => c.countOf('')),
            builder: (ctx, snap) => Text('[${snap.data ?? '…'}]',
                style: const TextStyle(
                    color: kTextHint, fontSize: TokFs.micro)),
          ),
          const SizedBox(width: 8),
        ]),
      ),
    );
    row = FavFolderDrop(
      controller: c,
      folderId: '',
      child: row,
    );
    return row;
  }

  Widget _nodeRow(FavNode node, int depth) {
    _order.add(node.id);
    final expanded = !_collapsed.contains(node.id);
    final canExpand = node.isFolder || node.isProject || node.isChain;

    Widget row = _rowBody(node, depth, canExpand, expanded);

    // 拖拽源（所有类型都可拖；多选时整组跟随——审计问题 6）。
    final inSel = c.selected.contains(node.id);
    final payloadIds =
        inSel && c.selected.length > 1 ? c.selected.toList() : [node.id];
    final draggingRow = row;
    row = _dragSource(
      payloadIds: payloadIds,
      feedbackLabel: payloadIds.length > 1
          ? '${node.name}（等 ${payloadIds.length} 项）'
          : node.name,
      childWhenDragging: Opacity(opacity: 0.35, child: draggingRow),
      child: draggingRow,
    );

    // 文件夹整行投放（审计问题 5：整行热区）。
    if (node.isFolder) {
      row = FavFolderDrop(
        controller: c,
        folderId: node.id,
        onHoverExpand: () {
          if (_collapsed.remove(node.id) && mounted) setState(() {});
        },
        child: row,
      );
    }

    if (canExpand && expanded) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [row, _kidsSection(node, depth + 1)],
      );
    }
    return row;
  }

  Widget _kidsSection(FavNode node, int depth) {
    return FutureBuilder<List<FavNode>>(
      future:
          _kidsFutures.putIfAbsent(node.id, () => visibleChildrenOf(c, node)),
      builder: (ctx, snap) {
        final kids = snap.data;
        if (kids == null) {
          return Padding(
            padding: EdgeInsets.only(left: 8.0 + depth * 16.0, top: 4),
            child: const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final k in kids) _nodeRow(k, depth)],
        );
      },
    );
  }

  Widget _rowBody(FavNode node, int depth, bool canExpand, bool expanded) {
    final selected = c.selected.contains(node.id);
    final visible = _effectiveVisible(node);
    return InkWell(
      onTap: () => _onTapNode(node),
      onSecondaryTapUp: (d) {
        c.selectOnly(node.id);
        _anchor = node.id;
        showFavNodeMenu(context, c, node,
            isDesktop: PlatformCaps.isDesktop,
            position: d.globalPosition,
            extra: widget.menuExtra);
      },
      onLongPress: () {
        // 移动端：长按进入多选。
        if (!c.selected.contains(node.id)) {
          c.toggleSelect(node.id);
          _anchor = node.id;
        }
      },
      child: Container(
        height: _rowH,
        padding: EdgeInsets.only(left: 8.0 + depth * 16.0, right: 2),
        color: selected ? kAccent.withValues(alpha: 0.14) : null,
        child: Opacity(
          opacity: visible ? 1.0 : 0.45,
          child: Row(children: [
            if (canExpand)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() {
                  if (!_collapsed.remove(node.id)) {
                    _collapsed.add(node.id);
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 8),
                  child: Icon(
                      expanded ? Icons.remove : Icons.add,
                      size: 13,
                      color: kTextSub),
                ),
              )
            else
              SizedBox(width: widget.compact ? 30 : 23),
            _nodeIcon(node),
            const SizedBox(width: 6),
            Expanded(child: _nodeTitle(node)),
            if (node.isProject) ...[
              _tag(favKindTag(node), favKindColor(node)),
              const SizedBox(width: 6),
              Text('${node.project?.count ?? 0} 点',
                  style: const TextStyle(
                      color: kTextSub, fontSize: TokFs.micro)),
              const SizedBox(width: 2),
            ],
            if (node.isFolder)
              FutureBuilder<int>(
                future: _counts.putIfAbsent(
                    node.id, () => c.countOf(node.id)),
                builder: (ctx, snap) => Text('[${snap.data ?? '…'}]',
                    style: const TextStyle(
                        color: kTextHint, fontSize: TokFs.micro)),
              ),
            if (widget.projectTrailing != null && node.isProject)
              widget.projectTrailing!(context, node),
            // compact（移动）模式：所有行尾「⋯」→ 共享节点菜单（移动端底弹样式）。
            // 文件夹/mark/chain 行此前在移动端没有菜单入口。
            if (widget.compact) _compactMenuButton(node),
            _eyeButton(node),
          ]),
        ),
      ),
    );
  }

  /// compact（移动）行尾「⋯」：打开共享节点菜单（移动端底弹样式）。
  /// 长按手势仍归多选（移动线），这里不动。
  Widget _compactMenuButton(FavNode node) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      tooltip: '更多操作',
      onPressed: () => showFavNodeMenu(context, c, node,
          isDesktop: false, extra: widget.menuExtra),
      icon: const Icon(Icons.more_vert, size: 16, color: kTextHint),
    );
  }

  Widget _nodeIcon(FavNode node) {
    if (node.isFolder) {
      return Icon(Icons.folder,
          size: widget.compact ? 20 : 16,
          color: const Color(0xFFE6A23C));
    }
    if (node.isChain) {
      return Icon(Icons.route,
          size: widget.compact ? 20 : 16, color: kTextSub);
    }
    // project / mark：符号圆点。
    final bg = node.color != 0
        ? Color(node.color)
        : (node.isProject ? favKindColor(node) : kTextSub);
    final sym = node.symbol.isNotEmpty
        ? node.symbol
        : (node.name.isNotEmpty ? node.name.substring(0, 1) : '·');
    final s = widget.compact ? 22.0 : 16.0;
    return Container(
      width: s,
      height: s,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(sym,
          style: TextStyle(
              color: Colors.white,
              fontSize: widget.compact ? 11 : 9,
              height: 1.0)),
    );
  }

  Widget _nodeTitle(FavNode node) {
    const style = TextStyle(color: kTextMain, fontSize: TokFs.body);
    if (node.isMark) {
      final note = node.label?.note.trim() ?? '';
      return Row(children: [
        Flexible(
          child: Text(node.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style),
        ),
        if (note.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: kTextHint, fontSize: TokFs.micro)),
          ),
        ],
      ]);
    }
    return Text(node.name,
        maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
  }

  Widget _tag(String text, Color color) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(TokR.s),
      ),
      child:
          Text(text, style: TextStyle(color: color, fontSize: TokFs.micro)),
    );
  }

  /// 每行独立 eye（审计问题 2）。
  Widget _eyeButton(FavNode node) {
    final visible = c.isVisible(node.id);
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      tooltip: visible ? '隐藏' : '显示',
      onPressed: () => setNodeVisible(context, c, node, !visible),
      icon: Icon(visible ? Icons.visibility : Icons.visibility_off,
          size: 16, color: visible ? kAccent : kTextHint),
    );
  }

  /// 生效可见性：自己 + 所有祖先都可见才算可见。
  bool _effectiveVisible(FavNode node) {
    for (final n in c.pathOf(node.id)) {
      if (!c.isVisible(n.id)) return false;
    }
    return true;
  }

  void _onTapNode(FavNode node) {
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (ctrl) {
      c.toggleSelect(node.id);
      _anchor = node.id;
      return;
    }
    if (kb.isShiftPressed && _anchor.isNotEmpty) {
      _rangeSelect(node.id);
      return;
    }
    // 多选模式下点选 = 切换选中（toggle），不执行打开/定位/展开；
    // 选空后回到普通模式，下一次点选恢复默认动作。
    if (c.selected.isNotEmpty) {
      c.toggleSelect(node.id);
      _anchor = node.id;
      return;
    }
    _anchor = node.id;
    if (node.isFolder) {
      c.selectTreeFolder(node.id);
      // 单击即展开（奥维手感）。
      if (_collapsed.remove(node.id)) setState(() {});
    } else if (node.isProject) {
      widget.onOpenProject?.call(node);
    } else if (node.isMark) {
      _locateMark(node);
    } else if (node.isChain) {
      setState(() {
        if (!_collapsed.remove(node.id)) _collapsed.add(node.id);
      });
    }
  }

  void _rangeSelect(String id) {
    final a = _order.indexOf(_anchor);
    final b = _order.indexOf(id);
    if (a < 0 || b < 0) {
      c.toggleSelect(id);
      _anchor = id;
      return;
    }
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    c.selectAll(_order.sublist(lo, hi + 1).where((e) => e.isNotEmpty));
    _anchor = id;
  }

  /// 定位：mark 直接调回调；project/chain 取首个点位包装成 mark 节点。
  Future<void> _locateMark(FavNode node) async {
    final cb = widget.onLocate;
    if (cb == null) return;
    if (node.isMark && node.label != null) {
      await cb(node);
      return;
    }
    final cid = node.isProject ? node.id : (node.chainCid ?? '');
    if (cid.isEmpty) return;
    final labels = await c.labelsOf(cid);
    if (labels.isEmpty) {
      if (mounted) toast(context, '「${node.name}」内无点位');
      return;
    }
    await cb(FavNode.markNode(labels.first, pid: cid, cid: cid));
  }

  // ---------- 搜索模式 ----------

  Widget _buildSearch() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 搜索模式之上保留文件夹投放行（审计问题 3）。
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Text('文件夹（可直接拖放）',
              style: TextStyle(color: kTextHint, fontSize: TokFs.micro)),
        ),
        for (final f in c.folders) _searchFolderRow(f),
        const Divider(height: 1, color: TokC.divider),
        FutureBuilder<List<FavSearchHit>>(
          future: _searchFuture,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(18),
                child: Center(
                    child: SizedBox(
                        height: 20,
                        width: 20,
                        child:
                            CircularProgressIndicator(strokeWidth: 2))),
              );
            }
            final hits = snap.data ?? const <FavSearchHit>[];
            if (hits.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(18),
                child: Text('没有匹配「$_activeQuery」的条目',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: kTextSub, fontSize: TokFs.body)),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final h in hits) _hitRow(h)],
            );
          },
        ),
      ],
    );
  }

  Widget _searchFolderRow(FavNode f) {
    _order.add(f.id);
    final crumbs = c.pathOf(f.id).map((n) => n.name).join(' / ');
    final selected = c.treeSelectedFolderId == f.id;
    Widget row = InkWell(
      onTap: () {
        c.selectTreeFolder(f.id);
        if (c.selected.isNotEmpty) c.clearSelection();
      },
      child: Container(
        height: _rowH,
        padding: const EdgeInsets.only(left: 12, right: 2),
        color: selected ? kAccent.withValues(alpha: 0.14) : null,
        child: Row(children: [
          const Icon(Icons.folder,
              size: 16, color: Color(0xFFE6A23C)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(crumbs,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: kTextMain, fontSize: TokFs.body)),
          ),
          if (widget.compact) _compactMenuButton(f),
          _eyeButton(f),
        ]),
      ),
    );
    return FavFolderDrop(
      controller: c,
      folderId: f.id,
      child: row,
    );
  }

  Widget _hitRow(FavSearchHit h) {
    final node = h.node;
    _order.add(node.id);
    final crumbs = h.path.length > 1
        ? h.path.sublist(0, h.path.length - 1).map((n) => n.name).join(' / ')
        : '根目录';
    final visible = _effectiveVisible(node);
    Widget row = InkWell(
      onTap: () => _onTapNode(node),
      onSecondaryTapUp: (d) {
        c.selectOnly(node.id);
        _anchor = node.id;
        showFavNodeMenu(context, c, node,
            isDesktop: PlatformCaps.isDesktop,
            position: d.globalPosition,
            extra: widget.menuExtra);
      },
      child: Container(
        height: _rowH,
        padding: const EdgeInsets.only(left: 12, right: 2),
        color: c.selected.contains(node.id)
            ? kAccent.withValues(alpha: 0.14)
            : null,
        child: Opacity(
          opacity: visible ? 1.0 : 0.45,
          child: Row(children: [
            _nodeIcon(node),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: kTextMain, fontSize: TokFs.body)),
                  Text(crumbs,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: kTextHint, fontSize: TokFs.micro)),
                ],
              ),
            ),
            if (widget.compact) _compactMenuButton(node),
            _eyeButton(node),
          ]),
        ),
      ),
    );
    // 搜索命中也可拖（拖到上方文件夹投放行）。
    final inSel = c.selected.contains(node.id);
    final payloadIds =
        inSel && c.selected.length > 1 ? c.selected.toList() : [node.id];
    row = _dragSource(
      payloadIds: payloadIds,
      feedbackLabel: node.name,
      childWhenDragging: Opacity(opacity: 0.35, child: row),
      child: row,
    );
    return row;
  }

  /// 拖拽源：桌面（鼠标）用 [Draggable] 即拖；移动端用 [LongPressDraggable]，
  /// 行上竖滑必须留给滚动（P0：Draggable 会吞掉竖滑，树几乎无法滚动）。
  /// 移动端长按同时进入多选（行内 InkWell onLongPress）并拿起拖拽，
  /// 松手取消拖拽后选中保留，语义自洽。
  Widget _dragSource({
    required List<String> payloadIds,
    required String feedbackLabel,
    required Widget child,
    Widget? childWhenDragging,
  }) {
    final feedback = Material(
      color: TokC.card,
      elevation: 4,
      borderRadius: BorderRadius.circular(TokR.s),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(feedbackLabel,
            style: const TextStyle(color: kTextMain, fontSize: TokFs.small)),
      ),
    );
    if (PlatformCaps.isDesktop) {
      return Draggable<FavDragPayload>(
        data: FavDragPayload(payloadIds),
        onDragStarted: () => favDragInProgress.value = true,
        onDragEnd: (_) => favDragInProgress.value = false,
        onDraggableCanceled: (_, _) => favDragInProgress.value = false,
        feedback: feedback,
        childWhenDragging: childWhenDragging ?? child,
        child: child,
      );
    }
    return LongPressDraggable<FavDragPayload>(
      data: FavDragPayload(payloadIds),
      onDragStarted: () => favDragInProgress.value = true,
      onDragEnd: (_) => favDragInProgress.value = false,
      onDraggableCanceled: (_, _) => favDragInProgress.value = false,
      feedback: feedback,
      childWhenDragging: childWhenDragging ?? child,
      child: child,
    );
  }
}
