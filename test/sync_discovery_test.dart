// UDP 发现广播解析测试（纯函数，不发真实广播）。
import 'package:flutter_test/flutter_test.dart';

import 'package:ovimap/sync/client/server_discovery.dart';
import 'package:ovimap/sync/sync_protocol.dart';

void main() {
  group('parseBeacon', () {
    test('合法广播解析出 name/host/port', () {
      final s = parseBeacon('$kDiscoveryMagic 我的电脑 47820', '192.168.1.10');
      expect(s, isNotNull);
      expect(s!.name, '我的电脑');
      expect(s.host, '192.168.1.10');
      expect(s.port, 47820);
      expect(s.baseUrl, 'http://192.168.1.10:47820');
    });

    test('多余空白仍可解析', () {
      final s = parseBeacon(
        '  $kDiscoveryMagic   电脑A   47820  ',
        '192.168.1.11',
      );
      expect(s, isNotNull);
      expect(s!.name, '电脑A');
      expect(s.port, 47820);
    });

    test('魔串不对 → null', () {
      expect(parseBeacon('OVIMAP_SYNC/2 电脑 47820', '192.168.1.10'), isNull);
      expect(parseBeacon('HELLO 电脑 47820', '192.168.1.10'), isNull);
      expect(parseBeacon('', '192.168.1.10'), isNull);
    });

    test('字段数不对 → null', () {
      expect(parseBeacon('$kDiscoveryMagic 电脑', '192.168.1.10'), isNull);
      expect(
        parseBeacon('$kDiscoveryMagic 电脑 47820 extra', '192.168.1.10'),
        isNull,
      );
    });

    test('端口非法 → null', () {
      expect(parseBeacon('$kDiscoveryMagic 电脑 abc', '192.168.1.10'), isNull);
      expect(parseBeacon('$kDiscoveryMagic 电脑 0', '192.168.1.10'), isNull);
      expect(parseBeacon('$kDiscoveryMagic 电脑 99999', '192.168.1.10'), isNull);
      expect(parseBeacon('$kDiscoveryMagic 电脑 -1', '192.168.1.10'), isNull);
    });

    test('name 为空或源 IP 为空 → null', () {
      expect(parseBeacon('$kDiscoveryMagic  47820', '192.168.1.10'), isNull);
      expect(parseBeacon('$kDiscoveryMagic 电脑 47820', ''), isNull);
    });
  });
}
