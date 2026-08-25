import 'dart:io';

import 'package:flutter/services.dart';
import 'package:miru/services/logging/logger.dart';

class PlatformEnvironmentService {
  PlatformEnvironmentService._();

  static const _intentChannel = MethodChannel('io.github.disenthrallclaude.miru/intent');

  static Future<bool> isInMultiWindowMode() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await _intentChannel.invokeMethod('checkIfInMultiWindowMode');
    } on PlatformException catch (e) {
      MiruLogger().e("Failed to check multi window mode: '${e.message}'.");
      return false;
    }
  }

  static Future<bool> isRunningOnX11() async {
    if (!Platform.isLinux) {
      return false;
    }
    try {
      return await _intentChannel.invokeMethod('isRunningOnX11');
    } on PlatformException catch (e) {
      MiruLogger().e("Failed to check X11 environment: '${e.message}'.");
      return false;
    }
  }

  static Future<int> getAndroidSdkVersion() async {
    if (!Platform.isAndroid) {
      return 0;
    }
    try {
      return await _intentChannel.invokeMethod('getAndroidSdkVersion');
    } on PlatformException catch (e) {
      MiruLogger().e("Failed to get Android SDK version: '${e.message}'.");
      return 0;
    }
  }
}
