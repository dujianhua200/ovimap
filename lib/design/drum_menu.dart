/// 配盘表菜单扩展点（只暴露、不接线）。
///
/// 由协调者把 [buildDrumMenuExtra] 的返回值作为 `FavMenuExtra` 传入
/// `showFavNodeMenu(..., extra: ...)`（桌面 `left_panel` / 移动端 drawer
/// 各自传入）。对 `kind == project` 的节点提供「生成配盘表」。
library;
import 'package:flutter/material.dart';

import '../ui/favorites/tree_menus.dart';
import 'drum_plan_page.dart';

/// 构建配盘表的菜单扩展：工程节点 →「生成配盘表」。
///
/// 点击后经 `FavTreeController.labelsOf` 取该工程全部点位，
/// 推入 [DrumPlanPage]（内部按 chains 拆段计算）。
FavMenuExtra buildDrumMenuExtra() => FavMenuExtra(
      entries: (node) => node.isProject
          ? const [
              PopupMenuItem<String>(
                value: 'extra:drumPlan',
                height: 34,
                child: Text('生成配盘表'),
              ),
            ]
          : const [],
      onSelected: (context, c, node, value) async {
        if (value != 'extra:drumPlan' || !node.isProject) return;
        final labels = await c.labelsOf(node.id);
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DrumPlanPage(
              projectName: node.name,
              labels: labels,
            ),
          ),
        );
      },
    );
