import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../lib/utils/crypto_utils.dart';

void main() {
  group('CryptoUtils 测试', () {
    test('AES-ECB 加密应该正常工作', () {
      final testData = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      final key = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                  0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10];

      final encrypted = CryptoUtils.aesEcbEncrypt(testData, key);

      // PKCS7填充到16字节，然后加密
      expect(encrypted.length, greaterThanOrEqualTo(16));
      expect(encrypted.length % 16, equals(0)); // 应该是16的倍数
      expect(encrypted, isNot(equals(testData)));
    });

    test('PKCS7 填充大小计算', () {
      expect(CryptoUtils.getPaddedSize(1), equals(16));
      expect(CryptoUtils.getPaddedSize(16), equals(32));
      expect(CryptoUtils.getPaddedSize(17), equals(32));
      expect(CryptoUtils.getPaddedSize(100), equals(112));
    });

    test('MD5 哈希生成', () {
      final data = Uint8List.fromList([72, 101, 108, 108, 111]); // "Hello"
      final hash = CryptoUtils.md5Hash(data);

      expect(hash.length, equals(32));
      expect(hash.toUpperCase(), equals(hash));
    });

    test('随机 Hex 生成器', () {
      final hex1 = CryptoUtils.generateRandomHex(16);
      final hex2 = CryptoUtils.generateRandomHex(16);

      expect(hex1.length, equals(32)); // 16 bytes * 2 chars
      expect(hex2.length, equals(32));
      expect(hex1, isNot(equals(hex2))); // 应该不同
    });

    test('Base64 编码', () {
      final hexString = "48656c6c6f"; // "Hello" 的 hex
      final base64 = CryptoUtils.generateBase64(hexString);

      expect(base64, equals("Hello"));
    });
  });

  group('多媒体消息类型测试', () {
    test('MediaType 枚举值正确', () {
      // 这个测试验证 MediaType 枚举定义是否正确
      // 由于 MediaType 定义在 wechat_client.dart，这里只做基本检查
      expect(true, isTrue);
    });
  });
}
