// 标签个体样式覆盖（symColor / symShape / symText）：
// 纯加法字段的 JSON 往返 / 老数据缺省 / clone，以及 effectiveSymbolStyle
// 的覆盖优先、缺省回退口径。
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/ui/label_marker.dart';

void main() {
  group('MapLabel 样式覆盖字段', () {
    test('缺省值：0 / 空 / 空，toJson 不写出（老格式零变化）', () {
      final l = MapLabel(typeId: 'pipe');
      expect(l.symColor, 0);
      expect(l.symShape, '');
      expect(l.symText, '');
      final j = l.toJson();
      expect(j.containsKey('symColor'), isFalse);
      expect(j.containsKey('symShape'), isFalse);
      expect(j.containsKey('symText'), isFalse);
    });

    test('非默认写出并往返还原', () {
      final l = MapLabel(
        typeId: 'fiberbox',
        symColor: 0xFFE53935,
        symShape: 'dot',
        symText: '光',
      );
      final j = l.toJson();
      expect(j['symColor'], 0xFFE53935);
      expect(j['symShape'], 'dot');
      expect(j['symText'], '光');
      final back = MapLabel.fromJson(j);
      expect(back.symColor, 0xFFE53935);
      expect(back.symShape, 'dot');
      expect(back.symText, '光');
    });

    test('老 JSON（无样式键）读出缺省值', () {
      final old = <String, dynamic>{
        'id': 'x1',
        'typeId': 'pipe',
        'seq': 3,
        'lat': 32.0,
        'lon': 114.0,
        'note': '',
        'name': '',
        'lineGroupId': 'g',
        'distLabel': '',
        'segKind': 0,
        'segCable': '',
        'holes': 0,
        'usedHoles': 0,
        'splitterRatio': '',
        'topoParentId': '',
        'cableSpec': '',
        'cableCores': 0,
      };
      final l = MapLabel.fromJson(old);
      expect(l.symColor, 0);
      expect(l.symShape, '');
      expect(l.symText, '');
    });

    test('clone 拷贝三字段且互不影响', () {
      final l = MapLabel(
        typeId: 'pipe',
        symColor: 0xFF2E7D32,
        symShape: 'tri',
        symText: 'AB',
      );
      final c = l.clone();
      expect(c.symColor, 0xFF2E7D32);
      expect(c.symShape, 'tri');
      expect(c.symText, 'AB');
      c.symColor = 0;
      c.symShape = '';
      expect(l.symColor, 0xFF2E7D32);
      expect(l.symShape, 'tri');
    });
  });

  group('effectiveSymbolStyle', () {
    test('无覆盖 → 完全回退类型预置', () {
      final l = MapLabel(typeId: 'manhole'); // oval / 人 / 0xFF00838F
      final (color, shape, symbol) = effectiveSymbolStyle(l);
      expect(color, l.type.color);
      expect(shape, 'oval');
      expect(symbol, '人');
    });

    test('全覆盖 → 三项都用覆盖值（符号字优先于名称）', () {
      final l = MapLabel(
        typeId: 'pipe',
        name: '杆1',
        symColor: 0xFFE53935,
        symShape: 'box',
        symText: 'X',
      );
      final (color, shape, symbol) = effectiveSymbolStyle(l);
      expect(color, const Color(0xFFE53935));
      expect(shape, 'box');
      expect(symbol, 'X');
    });

    test('部分覆盖：只改颜色，形状/符号字仍回退', () {
      final l = MapLabel(typeId: 'fiberbox', symColor: 0xFF000000);
      final (color, shape, symbol) = effectiveSymbolStyle(l);
      expect(color, const Color(0xFF000000));
      expect(shape, 'box'); // fiberbox 类型形状
      expect(symbol, '纤'); // fiberbox 类型符号字
    });

    test('部分覆盖：只改形状', () {
      final l = MapLabel(typeId: 'pipe', symShape: 'dot');
      final (_, shape, _) = effectiveSymbolStyle(l);
      expect(shape, 'dot');
    });

    test('无覆盖且有名称 → 符号字沿用历史口径（名称优先）', () {
      final l = MapLabel(typeId: 'pipe', name: 'P12');
      final (_, _, symbol) = effectiveSymbolStyle(l);
      expect(symbol, 'P12');
    });

    test('符号字覆盖优先于名称', () {
      final l = MapLabel(typeId: 'pipe', name: 'P12', symText: '杆');
      final (_, _, symbol) = effectiveSymbolStyle(l);
      expect(symbol, '杆');
    });
  });
}
