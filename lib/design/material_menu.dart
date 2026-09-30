import 'package:flutter/material.dart';

import '../models/fav_node.dart';
import '../state/fav_tree_controller.dart';
import '../ui/favorites/tree_menus.dart';
import 'material_table_page.dart';

/// 收藏树右键/长按菜单的材料表入口（只暴露扩展点，不接线）。
///
/// 对 kind == project / kind == folder 的节点提供「汇总材料表」菜单项，
/// 选中后打开 [MaterialTablePage]。
///
/// 接线由协调者统一做：把本函数返回的 [FavMenuExtra] 与其它 Extra 组合后
/// 传入 `showFavNodeMenu(..., extra: ...)` 即可。本文件不改动
/// left_panel.dart / fav_mobile_actions.dart / tree_menus.dart。
FavMenuExtra buildMaterialMenuExtra() {
  return FavMenuExtra(
    entries: (FavNode node) {
      if (!node.isProject && !node.isFolder) {
        return const <PopupMenuEntry<String>>[];
      }
      return const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'extra:material',
          height: 34,
          child: Text('汇总材料表'),
        ),
      ];
    },
    onSelected: (
      BuildContext context,
      FavTreeController c,
      FavNode node,
      String value,
    ) async {
      if (value != 'extra:material') return;
      if (!node.isProject && !node.isFolder) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MaterialTablePage(controller: c, node: node),
        ),
      );
    },
  );
}
