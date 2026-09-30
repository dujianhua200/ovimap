// 勘察表单（Phase 5）测试：
// - SurveyForm 序列化/反序列化往返；
// - 表单写入 label.extra['survey'] 时与 extra 里其他键共存、互不覆盖；
// - MapLabel extra 纯加法：无 extra 时 toJson 不写键、老数据 fromJson 为 null；
// - SurveyStore 照片相对路径拼接与真实导入拷贝。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovimap/models/map_label.dart';
import 'package:ovimap/services/app_paths.dart';
import 'package:ovimap/survey/survey_form.dart';
import 'package:ovimap/survey/survey_store.dart';

SurveyForm _sample() => SurveyForm(
      surveyor: '李工',
      poleType: '8米水泥杆',
      poleHeight: 8,
      envDesc: '道路东侧绿化带，无遮挡',
      canErect: true,
      advice: '沿路东侧架空敷设',
      surveyedAt: DateTime(2026, 9, 30, 10, 30),
      photos: ['survey/c1/l1/a.jpg', 'survey/c1/l1/b.jpg'],
    );

void main() {
  group('SurveyForm 序列化', () {
    test('toJson/fromJson 往返保持全部字段', () {
      final f = _sample();
      final g = SurveyForm.fromJson(Map<String, dynamic>.from(f.toJson()));
      expect(g.surveyor, '李工');
      expect(g.poleType, '8米水泥杆');
      expect(g.poleHeight, 8);
      expect(g.envDesc, '道路东侧绿化带，无遮挡');
      expect(g.canErect, isTrue);
      expect(g.advice, '沿路东侧架空敷设');
      expect(g.surveyedAt, DateTime(2026, 9, 30, 10, 30));
      expect(g.photos, ['survey/c1/l1/a.jpg', 'survey/c1/l1/b.jpg']);
    });

    test('缺键 fromJson 给出默认值（不抛异常）', () {
      final g = SurveyForm.fromJson({});
      expect(g.surveyor, '');
      expect(g.poleType, '');
      expect(g.poleHeight, isNull);
      expect(g.canErect, isTrue);
      expect(g.photos, isEmpty);
      // surveyedAt 缺省记为当前时间（允许 5 秒误差）。
      expect(
          DateTime.now().difference(g.surveyedAt).abs().inSeconds, lessThan(5));
    });

    test('空照片/空杆高不落盘（纯加法）', () {
      final j = SurveyForm(surveyor: '王工').toJson();
      expect(j.containsKey('photos'), isFalse);
      expect(j.containsKey('poleHeight'), isFalse);
    });

    test('JSON 字符串往返（磁盘格式）', () {
      final f = _sample();
      final g = SurveyForm.fromJson(
          jsonDecode(jsonEncode(f.toJson())) as Map<String, dynamic>);
      expect(g.surveyor, '李工');
      expect(g.photos, hasLength(2));
    });
  });

  group('extra[\'survey\'] 与其他键共存', () {
    test('applyTo 只写 survey 键，其他键原样保留', () {
      final l = MapLabel()
        ..extra = {
          'other': 'keep',
          'nested': {'a': 1}
        };
      _sample().applyTo(l);
      expect(l.extra!['other'], 'keep');
      expect(l.extra!['nested'], {'a': 1});
      expect(SurveyForm.fromLabel(l)!.surveyor, '李工');
    });

    test('无 survey 键时 fromLabel 返回 null', () {
      final l = MapLabel()..extra = {'other': 1};
      expect(SurveyForm.fromLabel(l), isNull);
      expect(SurveyForm.fromLabel(MapLabel()), isNull);
    });

    test('覆盖写回不影响其他键', () {
      final l = MapLabel();
      _sample().applyTo(l);
      final f2 = SurveyForm.fromLabel(l)!..surveyor = '赵工';
      f2.applyTo(l);
      expect(SurveyForm.fromLabel(l)!.surveyor, '赵工');
      expect(l.extra!.keys, ['survey']);
    });

    test('MapLabel JSON 往返保留 extra（含 survey 与其他键）', () {
      final l = MapLabel();
      l.extra = {'other': 'x'};
      _sample().applyTo(l);
      final back = MapLabel.fromJson(
          jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>);
      expect(back.extra!['other'], 'x');
      expect(SurveyForm.fromLabel(back)!.poleType, '8米水泥杆');
    });

    test('clone 深拷贝 extra：改克隆不影响原对象', () {
      final l = MapLabel();
      l.extra = {
        'survey': _sample().toJson(),
        'tags': ['a', 'b']
      };
      final c = l.clone();
      (c.extra!['survey'] as Map)['surveyor'] = '改了';
      (c.extra!['tags'] as List).add('c');
      expect(SurveyForm.fromLabel(l)!.surveyor, '李工');
      expect((l.extra!['tags'] as List), ['a', 'b']);
    });
  });

  group('MapLabel extra 纯加法（磁盘格式零破坏）', () {
    test('无 extra 时 toJson 不写 extra 键', () {
      expect(MapLabel().toJson().containsKey('extra'), isFalse);
    });

    test('extra 为空 map 时同样不写键', () {
      final l = MapLabel()..extra = {};
      expect(l.toJson().containsKey('extra'), isFalse);
    });

    test('老数据（无 extra 键）fromJson 后 extra 为 null', () {
      final back = MapLabel.fromJson(
          {'id': 'x', 'typeId': 'pole', 'lat': 1.0, 'lon': 2.0});
      expect(back.extra, isNull);
    });
  });

  group('SurveyStore 照片路径', () {
    test('relPath 拼接：survey/<cid>/<labelId>/<文件名>', () {
      expect(SurveyStore.relPath('cid1', 'lid1', 'a.jpg'),
          'survey/cid1/lid1/a.jpg');
    });

    test('importFile 真实拷贝并返回相对路径', () async {
      final tmp = Directory.systemTemp.createTempSync('ovimap_survey_');
      AppPaths.setBaseForTest(tmp);
      try {
        final src = File('${tmp.path}/src.jpg');
        await src.writeAsBytes([1, 2, 3, 4]);
        final rel =
            await SurveyStore.importFile('c1', 'l1', src.path);
        expect(rel, isNotNull);
        expect(rel, startsWith('survey/c1/l1/l1_'));
        expect(rel, endsWith('.jpg'));
        // 文件确实落到 photos/survey/c1/l1/ 下。
        final abs = await SurveyStore.absPath(rel!);
        expect(File(abs).existsSync(), isTrue);
        expect(File(abs).lengthSync(), 4);
      } finally {
        AppPaths.clearForTest();
        tmp.deleteSync(recursive: true);
      }
    });

    test('importFile 源文件不存在返回 null', () async {
      final tmp = Directory.systemTemp.createTempSync('ovimap_survey2_');
      AppPaths.setBaseForTest(tmp);
      try {
        expect(
            await SurveyStore.importFile(
                'c1', 'l1', '${tmp.path}/nope.jpg'),
            isNull);
      } finally {
        AppPaths.clearForTest();
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
