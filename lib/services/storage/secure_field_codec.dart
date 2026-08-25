import 'package:flutter/services.dart';
import 'package:miru/services/logging/logger.dart';

/// 敏感设置字段（如 WebDAV 密码）的加密编解码器。
///
/// Android 上通过 MethodChannel 调用 Android Keystore（AES-256/GCM，
/// 硬件级密钥，不可导出）完成加解密；其他平台或通道不可用时优雅降级
/// 为明文直存，功能不中断。
///
/// 密文格式固定以 `v1:` 开头，读取时据此区分历史明文数据，实现无缝迁移。
class SecureFieldCodec {
  static const MethodChannel _channel =
      MethodChannel('io.github.disenthrallclaude.miru/crypto');

  static const String _cipherPrefix = 'v1:';

  /// 是否为密文格式。
  static bool isEncrypted(String storedValue) =>
      storedValue.startsWith(_cipherPrefix);

  /// 加密明文。返回密文（`v1:` 前缀）；平台不支持或加密失败时原样返回，
  /// 保证保存操作永远成功（降级为明文，与旧行为一致）。
  static Future<String> encrypt(String plainText) async {
    if (plainText.isEmpty) {
      return plainText;
    }
    try {
      final result = await _channel.invokeMethod<String>(
        'encrypt',
        {'value': plainText},
      );
      if (result != null && result.isNotEmpty) {
        return result;
      }
      MiruLogger().w(
          'SecureFieldCodec: encrypt returned empty result, fallback to plaintext');
    } catch (e) {
      MiruLogger().w(
          'SecureFieldCodec: encrypt unavailable, fallback to plaintext',
          error: e);
    }
    return plainText;
  }

  /// 解密存储值：
  /// - 空值/历史明文直接透传；
  /// - `v1:` 密文解密成功返回明文；
  /// - 解密失败（如 Keystore 密钥被系统清除）返回 null，
  ///   由调用方决定提示用户重新输入，绝不能把密文当密码使用。
  static Future<String?> decrypt(String storedValue) async {
    if (storedValue.isEmpty || !isEncrypted(storedValue)) {
      return storedValue;
    }
    try {
      final result = await _channel.invokeMethod<String>(
        'decrypt',
        {'value': storedValue},
      );
      if (result == null || result.isEmpty) {
        MiruLogger()
            .e('SecureFieldCodec: decrypt returned empty, key may be lost');
        return null;
      }
      return result;
    } catch (e) {
      MiruLogger()
          .e('SecureFieldCodec: decrypt failed, key may be lost', error: e);
      return null;
    }
  }
}
