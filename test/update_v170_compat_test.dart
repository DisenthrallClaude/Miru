// v1.8.0 发版门禁：v1.7.0 的应用内更新逻辑（needUpdate + 资产匹配
// ['android', '.apk']，自 v1.7.0 起未改动）必须能识别 v1.8.0 Release。
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/update/auto_updater.dart';
import 'package:miru/utils/version.dart';

void main() {
  test('v1.7.0 → tag v1.8.0 判定为有更新；同版/旧版不提示', () {
    expect(needUpdate('1.7.0', 'v1.8.0'), isTrue);
    expect(needUpdate('1.8.0', 'v1.8.0'), isFalse);
    expect(needUpdate('1.8.0', 'v1.7.0'), isFalse);
  });

  test('资产名必须含 android 且为 .apk：Miru_android_1.8.0.apk 命中', () {
    final assets = [
      {
        'name': 'miru-v1.8.0-arm64.apk',
        'browser_download_url': 'https://x/miru-v1.8.0-arm64.apk',
      },
      {
        'name': 'Miru_android_1.8.0.apk',
        'browser_download_url': 'https://x/Miru_android_1.8.0.apk',
        'digest': 'sha256:abc',
      },
    ];
    final a = getUpdateAssetForType(assets, InstallationType.androidApk);
    expect(a?['name'], 'Miru_android_1.8.0.apk');
    expect(getUpdateFileHashFromAsset(a!), 'abc');
    // v1.7.0 自身的资产命名（无 android）不会被识别——发版必须带 android 名。
    expect(
        getUpdateAssetForType([assets.first], InstallationType.androidApk),
        isNull);
  });
}
