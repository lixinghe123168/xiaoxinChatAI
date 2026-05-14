import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

class CryptoUtils {
  static const int _aesBlockSize = 16;

  static Uint8List aesEcbEncrypt(Uint8List plaintext, List<int> key) {
    final keyObj = encrypt.Key(Uint8List.fromList(key));
    final encrypter = encrypt.Encrypter(encrypt.AES(keyObj, mode: encrypt.AESMode.ecb));
    
    final paddedData = _pkcs7Pad(plaintext);
    final encrypted = encrypter.encryptBytes(paddedData);
    
    return Uint8List.fromList(encrypted.bytes);
  }

  static Uint8List _pkcs7Pad(Uint8List data) {
    final padLen = _aesBlockSize - (data.length % _aesBlockSize);
    final padded = Uint8List(data.length + padLen);
    padded.setRange(0, data.length, data);
    padded.fillRange(data.length, padded.length, padLen);
    return padded;
  }

  static int getPaddedSize(int originalSize) {
    return ((originalSize ~/ _aesBlockSize) + 1) * _aesBlockSize;
  }

  static String md5Hash(Uint8List data) {
    return md5.convert(data).toString().toUpperCase();
  }

  static String generateRandomHex(int length) {
    final random = Random.secure();
    final bytes = List.generate(length, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String generateBase64(String hexString) {
    final bytes = ascii.encode(hexString);
    return base64.encode(bytes);
  }
}
