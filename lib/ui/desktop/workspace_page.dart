import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../geo/geo_util.dart';
import '../../models/map_label.dart';
import '../../services/export_saver.dart';
import '../../services/file_drop.dart';
import '../../services/photos.dart';
import '../../services/tile_cache.dart';
import '../../services/track_check.dart';
import '../../state/app_state.dart';
import '../../sync/sync_controller.dart';
import '../dialogs.dart';
import '../export_center.dart';
import '../map/map_canvas.dart';
import '../sync/sync_panel.dart';
import 'app_menu_bar.dart';
import 'context_menu.dart';
import 'left_panel.dart';
import 'right_panel.dart';
import 'shortcuts.dart';
import 'status_bar.dart';
import 'toolbar.dart';

/// 桌面外壳（Windows）：菜单栏 + 工具栏 + 三栏（左栏 / 地图 / 右栏）+ 状态栏 +
/// 快捷键（架构文档 §3.1 / §3.2 / T08）。
///
/// 地图渲染与交互复用共享核心 [MapCanvas]（`openDetailOnTap=false`，点选结果经
/// [MapCanvas.onSelect] 交给右栏展示）；本壳只承载桌面 Chrome 与桌面态。
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  final MapController _mc = MapController();
  final FocusNode _searchFocus = FocusNode();

  CacheTileProvider? _baseProvider;
  CacheTileProvider? _overlayProvider;
  String? _baseProviderFor;
  String? _overlayProviderFor;

  bool _mapReady = false;
  MapCamera? _cam;

  // ---- 布局（可拖拽/折叠） ----
  double _leftW = 260;
  double _rightW = 300;
  bool _leftCollapsed = false;
  bool _rightCollapsed = false;

  // ---- 选中（右栏展示） ----
  MapLabel? _selLabel;
  String _selCid = '';

  @override
  void initState() {
    super.initState();
    // T21：注册 Windows 资源管理器文件拖放（WM_DROPFILES → MethodChannel）。
    // 非 Windows 平台该通道永不触发，注册无副作用。
    FileDrop.register(_onFilesDropped);
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  // ================= 外部文件（拖入 / 打开）T21·T22 =================

  void _onFilesDropped(List<String> paths) {
    unawaited(_handleExternalFiles(paths));
  }

  Future<void> _handleExternalFiles(List<String> paths) async {
    final st = _st;
    final msg = await st.openExternalFiles(paths);
    if (!mounted) return;
    toast(context, msg);
  }

  /// 「打开工程文件」（文件菜单 / Ctrl+O）：选 `.ovimap` → 导入并打开。
  Future<void> _openProjectFile() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ovimap'],
        withData: false,
      );
    } catch (e) {
      if (mounted) toast(context, '打开文件选择器失败：$e');
      return;
    }
    if (picked == null || picked.files.isEmpty) return; // 用户取消：静默
    final p = picked.files.first.path;
    if (p == null || p.isEmpty) {
      if (mounted) toast(context, '无法获取所选文件的内容');
      return;
    }
    final msg = await _st.openExternalFiles(<String>[p]);
    if (mounted) toast(context, msg);
  }

  /// 「导出工程文件 (.ovimap)」（文件菜单）：把当前打开的工程另存为 `.ovimap`。
  Future<void> _exportProjectFile() async {
    final st = _st;
    final cid = st.activeCollectionId;
    if (cid.isEmpty) {
      toast(context, '请先打开一个已保存的工程，再导出工程文件');
      return;
    }
    final f = await st.buildProjectFile(cid);
    if (!mounted) return;
    if (f == null) {
      toast(context, '导出工程文件失败：找不到该工程的原始文件');
      return;
    }
    await ExportSaver.saveOrShare(context, f,
        suggestedName: f.uri.pathSegments.last);
  }

  // ================= 回调 =================

  AppState get _st => context.read<AppState>();

  void _newProject() {
    final st = _st;
    st.clearDraft();
    st.projectName = '';
    st.folderId = '';
    st.activeCollectionId = '';
    st.setMode(AppMode.edit);
    setState(() {
      _selLabel = null;
      _selCid = '';
    });
    st.refreshUi();
    toast(context, '已新建空白工程');
  }

  void _save() => showFinishDialog(context, _st);

  void _undo() {
    _st.undoDraft();
    setState(() {
      _selLabel = null;
      _selCid = '';
    });
  }

  void _redo() {
    _st.redo();
    setState(() {
      _selLabel = null;
      _selCid = '';
    });
  }

  void _deleteSelection() {
    final st = _st;
    if (st.selectedIds.isEmpty) {
      toast(context, '未选中点（可框选或在线组里选中）');
      return;
    }
    final n = st.deleteSelected();
    setState(() => _selLabel = null);
    toast(context, '已删除 $n 个点（Ctrl+Z 可撤销）');
  }

  void _export() => openExportCenter(context, _st);

  void _focusSearch() => _searchFocus.requestFocus();

  Future<void> _topo() async {
    final st = _st;
    if (st.mode == AppMode.topoLink) {
      st.endTopoLink();
      return;
    }
    for (final m in st.collections) {
      final ok = await st.startTopoLink(m);
      if (!mounted) return;
      if (ok) {
        toast(context, '拓扑连线：点起点箱体 → 点终点箱体');
        return;
      }
    }
    toast(context, '没有含可连线箱体（光交/分纤盒/分光器箱/ONU/机房/基站/引上）的收藏工程');
  }

  void _track() {
    final st = _st;
    if (st.recording) {
      st.toggleRecordPause();
      return;
    }
    toast(context, '桌面端无 GPS 定位，不支持轨迹记录；请在移动端沿线走查录制');
  }

  void _locateMe() {
    final st = _st;
    if (!st.hasFix || st.curLat == null || st.curLon == null) {
      toast(context, '桌面端无 GPS 定位；可右键「粘贴坐标点」或搜索定位到目标');
      return;
    }
    final d = st.toDisplay(st.curLat!, st.curLon!);
    _mc.moveAndRotate(LatLng(d[0], d[1]),
        _mc.camera.zoom < 16 ? 17.5 : _mc.camera.zoom, _mc.camera.rotation);
    st.setFollow(true);
    toast(context, '已定位到当前位置');
  }

  void _zoomIn() {
    final c = _mc.camera;
    _mc.moveAndRotate(c.center, c.zoom + 1, c.rotation);
  }

  void _zoomOut() {
    final c = _mc.camera;
    _mc.moveAndRotate(c.center, c.zoom - 1, c.rotation);
  }

  Future<void> _onOffline() async {
    final st = _st;
    await showOfflineDialog(context, st, _mc, _baseProvider!);
  }

  /// 存储清理：清图源缓存 + 清未引用照片（与移动端同一口径）。
  Future<void> _storageCleanup() async {
    final st = _st;
    final n = await _baseProvider?.clearDiskCache() ?? 0;
    _baseProviderFor = null; // 强制重建 provider
    if (mounted) setState(() {});
    final refs = <String>{};
    void eat(List<MapLabel> ls) {
      for (final e in ls) {
        refs.addAll(e.photoPaths);
      }
    }

    eat(st.labels);
    for (final m in st.collections) {
      eat(await st.store.loadCollection(m.id));
    }
    final p = await PhotoService.purgeOrphans([refs]);
    if (!mounted) return;
    toast(context,
        '存储清理完成：图源缓存${n > 0 ? '已清' : '无'} · 未引用照片${p > 0 ? '已清 $p 个' : '无'}');
  }

  void _showSyncInfo() {
    // 打开同步面板（T17）。sync 以可空方式取得，未接入时面板退化为「本地模式」。
    showSyncPanel(context, context.read<SyncController?>(), _st);
  }

  // ---- 工具：杆路点表 / 轨迹核查（桌面精简版，复用共享逻辑） ----

  Future<void> _showPoleTable() async {
    final st = _st;
    if (st.labels.isEmpty) {
      toast(context, '当前项目没有点');
      return;
    }
    final chains = buildLabelChains(st.labels);
    await showDarkDialog(
      context,
      title: '杆路点表',
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: chains.isEmpty
            ? const Center(
                child: Text('没有参与连线的点（箱体请从地图上直接点选）',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kTextSub, fontSize: 13)))
            : ListView(
                children: [
                  for (var ci = 0; ci < chains.length; ci++) ...[
                    Builder(builder: (ctx) {
                      var len = 0.0;
                      for (var i = 1; i < chains[ci].length; i++) {
                        final p = chains[ci][i];
                        len += p.distanceM ??
                            GeoUtil.haversine(chains[ci][i - 1].lat,
                                chains[ci][i - 1].lon, p.lat, p.lon);
                      }
                      return Container(
                        color: const Color(0xFF232A31),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        child: Text(
                            '链 ${ci + 1} · ${chains[ci].length} 点 · 全长 ${_fmtChainLen(len)}',
                            style: const TextStyle(
                                color: kAccent, fontSize: 12.5)),
                      );
                    }),
                    for (final l in chains[ci])
                      ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 11,
                          backgroundColor: l.type.color,
                          child: Text(
                              l.name.trim().isNotEmpty
                                  ? l.name.trim().substring(0, 1)
                                  : (l.type.symbol.isEmpty
                                      ? l.type.name.substring(0, 1)
                                      : l.type.symbol),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11)),
                        ),
                        title: Text(
                            l.name.trim().isNotEmpty ? l.name.trim() : l.type.name,
                            style: const TextStyle(
                                color: kTextMain, fontSize: 13.5)),
                        subtitle: Text(_poleSub(l, chains[ci]),
                            style: const TextStyle(
                                color: kTextSub, fontSize: 11)),
                        onTap: () {
                          Navigator.pop(context);
                          final d = st.toDisplay(l.lat, l.lon);
                          _mc.move(LatLng(d[0], d[1]), _mc.camera.zoom);
                          setState(() {
                            _selLabel = l;
                            _selCid = '';
                          });
                        },
                      ),
                  ],
                ],
              ),
      ),
      actions: [
        darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
      ],
    );
  }

  String _poleSub(MapLabel l, List<MapLabel> chain) {
    final parts = <String>[];
    final i = chain.indexOf(l);
    if (i > 0) {
      final d = l.distanceM ??
          GeoUtil.haversine(chain[i - 1].lat, chain[i - 1].lon, l.lat, l.lon);
      parts.add('距上点 ${GeoUtil.fmtDist(d)}');
    }
    if (l.slackM > 0) {
      parts.add(
          '盘留${l.slackM == l.slackM.roundToDouble() ? l.slackM.toStringAsFixed(0) : l.slackM.toStringAsFixed(1)}m');
    }
    if (l.segCable.trim().isNotEmpty) parts.add(l.segCable.trim());
    if (l.photoPaths.isNotEmpty) parts.add('${l.photoPaths.length}图');
    return parts.isEmpty ? l.type.name : parts.join(' · ');
  }

  Future<void> _showTrackCheck() async {
    final st = _st;
    final tracks = st.collections.where((m) => m.kind == 'track').toList();
    if (tracks.isEmpty) {
      toast(context, '没有轨迹：先在线走查一遍并记录轨迹，再来核查');
      return;
    }
    final poles = [
      for (final chain in buildLabelChains(st.labels)) ...chain,
    ];
    if (poles.isEmpty) {
      toast(context, '当前项目没有杆路点，无法核查');
      return;
    }
    await showDarkDialog(
      context,
      title: '选择一条轨迹核查',
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final m in tracks)
              ListTile(
                dense: true,
                title: Text(m.name.isEmpty ? '未命名轨迹' : m.name,
                    style: const TextStyle(color: kTextMain, fontSize: 13.5)),
                subtitle: Text('${m.count} 点',
                    style: const TextStyle(color: kTextSub, fontSize: 11)),
                onTap: () async {
                  Navigator.pop(context);
                  final trackPts = await st.store.loadCollection(m.id);
                  final r = TrackChecker.check(trackPts, poles);
                  if (!mounted) return;
                  _showTrackReport(m.name, r);
                },
              ),
          ],
        ),
      ),
      actions: [
        darkTextBtn('取消', () => Navigator.pop(context), color: kTextSub),
      ],
    );
  }

  void _showTrackReport(String trackName, TrackCheckResult r) {
    showDarkDialog(
      context,
      title: '轨迹核查报告',
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('轨迹：$trackName',
                style: const TextStyle(color: kTextSub, fontSize: 12)),
            const SizedBox(height: 6),
            Text(
                '杆数 ${r.poleCount} · 轨迹全长 ${_fmtChainLen(r.trackLen)}\n'
                '平均偏移 ${r.avgOffset.toStringAsFixed(0)} 米（阈值 ${r.threshold.toStringAsFixed(0)} 米）',
                style: const TextStyle(color: kTextMain, fontSize: 13)),
            const SizedBox(height: 10),
            Text(
                r.outliers.isEmpty
                    ? '✓ 全部杆位偏移在阈值内，没有漏杆/错位迹象'
                    : '⚠ ${r.outliers.length} 根杆偏移超阈值，按偏移从大到小：',
                style: TextStyle(
                    color: r.outliers.isEmpty
                        ? const Color(0xFF69F0AE)
                        : const Color(0xFFFFB74D),
                    fontSize: 13)),
            for (final (pole, off) in r.outliers.take(10))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                    '· ${pole.name.trim().isNotEmpty ? pole.name.trim() : pole.type.name}：偏移 ${off.toStringAsFixed(0)} 米',
                    style: const TextStyle(
                        color: Color(0xFFFFB74D), fontSize: 12.5)),
              ),
          ],
        ),
      ),
      actions: [
        darkTextBtn('关闭', () => Navigator.pop(context), color: kTextSub),
      ],
    );
  }

  String _fmtChainLen(double m) => m < 1000
      ? '${m.toStringAsFixed(0)}m'
      : '${(m / 1000).toStringAsFixed(2)}km';

  // ================= 构建 =================

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppState>();
    // 同步编排器以**可空**方式获取（未接入同步时返回 null，不抛异常）。
    final sync = context.watch<SyncController?>();
    if (!st.inited) {
      return const Scaffold(
        backgroundColor: Color(0xFF101418),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: kAccent),
              SizedBox(height: 14),
              Text('滑洲云图 启动中…',
                  style: TextStyle(color: kTextSub, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    // 图源变化时重建 provider（与移动端一致）。
    if (_baseProviderFor != st.curSource.id || _baseProvider == null) {
      _baseProvider = CacheTileProvider(
          sourceId: st.curSource.id,
          urlTemplate: st.curSource.normalizedUrl);
      _baseProviderFor = st.curSource.id;
    }
    final ovl = st.currentOverlay();
    if (ovl != null && _overlayProviderFor != ovl.id) {
      _overlayProvider = CacheTileProvider(
          sourceId: ovl.id, urlTemplate: ovl.normalizedUrl);
      _overlayProviderFor = ovl.id;
    } else if (ovl == null) {
      _overlayProvider = null;
      _overlayProviderFor = null;
    }

    return DesktopShortcuts(
      onSave: _save,
      onUndo: _undo,
      onRedo: _redo,
      onDeleteSelection: _deleteSelection,
      onExport: _export,
      onFocusSearch: _focusSearch,
      onOpenProject: _openProjectFile,
      child: Scaffold(
        backgroundColor: const Color(0xFF101418),
        body: Column(
          children: [
            AppMenuBar(
              st: st,
              onNewProject: _newProject,
              onSave: _save,
              onUndo: _undo,
              onRedo: _redo,
              onDeleteSelection: _deleteSelection,
              onExport: _export,
              onOffline: _onOffline,
              onStorageCleanup: _storageCleanup,
              onPoleTable: _showPoleTable,
              onTrackCheck: _showTrackCheck,
              onSync: _showSyncInfo,
              onOpenProject: _openProjectFile,
              onExportProject: _exportProjectFile,
            ),
            Toolbar(
              st: st,
              sync: sync,
              onZoomIn: _zoomIn,
              onZoomOut: _zoomOut,
              onTopo: _topo,
              onTrack: _track,
              onLocate: _locateMe,
              onUndo: _undo,
              onRedo: _redo,
              onDeleteSelection: _deleteSelection,
              onExport: _export,
              onSync: _showSyncInfo,
              leftCollapsed: _leftCollapsed,
              rightCollapsed: _rightCollapsed,
              onToggleLeft: () =>
                  setState(() => _leftCollapsed = !_leftCollapsed),
              onToggleRight: () =>
                  setState(() => _rightCollapsed = !_rightCollapsed),
            ),
            Expanded(child: _body(st)),
            StatusBar(
              st: st,
              sync: sync,
              centerText: _centerText(st),
              zoom: _cam?.zoom ?? st.initZoom,
              selectedCount: st.selectedIds.length,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(AppState st) {
    return LayoutBuilder(
      builder: (ctx, c) {
        // 窗口 < 1180 自动收起右栏，避免挤压地图。
        final showRight = !_rightCollapsed && c.maxWidth >= 1180;
        final showLeft = !_leftCollapsed;
        return Row(
          children: [
            if (showLeft) SizedBox(width: _leftW, child: _leftPanel(st)),
            if (showLeft)
              _dragDivider((dx) => setState(
                  () => _leftW = (_leftW + dx).clamp(200.0, 420.0))),
            Expanded(child: _mapStack(st)),
            if (showRight)
              _dragDivider((dx) => setState(
                  () => _rightW = (_rightW - dx).clamp(240.0, 460.0))),
            if (showRight)
              SizedBox(width: _rightW, child: _rightPanel(st)),
          ],
        );
      },
    );
  }

  Widget _leftPanel(AppState st) => LeftPanel(
        st: st,
        searchFocus: _searchFocus,
        onNewProject: _newProject,
      );

  Widget _rightPanel(AppState st) => RightPanel(
        st: st,
        label: _selLabel,
        sourceCid: _selCid,
        onCleared: () => setState(() {
          _selLabel = null;
          _selCid = '';
        }),
      );

  Widget _mapStack(AppState st) {
    return Stack(
      children: [
        MapCanvas(
          st: st,
          controller: _mc,
          baseProvider: _baseProvider!,
          overlayProvider: _overlayProvider,
          heading: 0,
          hasHeading: false,
          // 桌面：点选交给右栏（不直接弹对话框）。
          openDetailOnTap: false,
          interactionFlags: InteractiveFlag.all,
          onSelect: (label, cid) => setState(() {
            _selLabel = label;
            _selCid = cid;
          }),
          onMapReady: () {
            _mapReady = true;
          },
          onCameraChanged: (cam) => setState(() => _cam = cam),
          onSecondaryTap: (tap, point) => showMapContextMenu(
            context,
            st,
            globalPosition: tap.global,
            point: point,
            controller: _mc,
            onLocate: _locateMe,
          ),
          extraLayers: [
            MarkerLayer(
              // 相机取自 [_cam]（onCameraChanged 回传），**不可**用 `_mc.camera`：
              // 后者在首帧前会抛异常，且会在 release AOT 中触发整棵 UI 子树被裁。
              markers: _cam == null
                  ? const <Marker>[]
                  : buildBusinessMarkers(st, _cam!, mapReady: _mapReady),
            ),
          ],
        ),
        // 比例尺（左下）
        Positioned(
          left: 12,
          bottom: 12,
          child: _mapReady
              ? ScaleBar(camera: _mc.camera)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _dragDivider(void Function(double dx) onDrag) => MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
          child: Container(
            width: 6,
            color: Colors.white10,
            child: Center(
              child: Container(width: 1, color: Colors.white24),
            ),
          ),
        ),
      );

  String _centerText(AppState st) {
    final c = _cam?.center ??
        LatLng(st.toDisplay(st.initLat, st.initLon)[0],
            st.toDisplay(st.initLat, st.initLon)[1]);
    return GeoUtil.formatCoord(c.latitude, c.longitude, st.coordFmt);
  }
}
