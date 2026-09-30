import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../ui/design_tokens.dart';
import '../ui/dialogs.dart';
import '../ui/favorites/tree_menus.dart';
import 'pole_placer_page.dart';

/// 智能布杆菜单扩展点（仅暴露，不接线——接线由协调者统一做）。
///
/// 用法：把 [buildPoleMenuExtra] 的返回值传给 [showFavNodeMenu] 的 `extra` 参数
/// （桌面 left_panel / 移动 fav_mobile_actions 均可）。
/// 对 kind == project 的节点追加菜单项「智能布杆」，选中后打开布杆对话框。
FavMenuExtra buildPoleMenuExtra() => FavMenuExtra(
      entries: (node) {
        if (!node.isProject) return const <PopupMenuEntry<String>>[];
        return const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'extra:pole-place',
            height: 34,
            child: Text('智能布杆',
                style: TextStyle(color: kTextMain, fontSize: TokFs.body)),
          ),
        ];
      },
      onSelected: (context, c, node, value) async {
        if (value != 'extra:pole-place' || !node.isProject) return;
        final st = Provider.of<AppState>(context, listen: false);
        await showPolePlacerDialog(
          context,
          st: st,
          controller: c,
          projectNode: node,
        );
      },
    );
