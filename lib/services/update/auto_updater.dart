import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:miru/bean/dialog/dialog_helper.dart';
import 'package:miru/bean/dialog/update_dialog.dart';
import 'package:miru/request/clients/download_http_client.dart';
import 'package:miru/request/config/api_endpoints.dart';
import 'package:miru/services/logging/logger.dart';
import 'package:miru/services/storage/storage.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:miru/utils/device.dart';
import 'package:miru/utils/date_time.dart';
import 'package:miru/utils/version.dart';

/// 安装类型枚举
enum InstallationType {
  windowsMsix, // Miru_windows_1.7.5.msix
  windowsPortable, // Miru_windows_1.7.5.zip
  linuxDeb, // Miru_linux_1.7.5_amd64.deb
  linuxTar, // Miru_linux_1.7.5_amd64.tar.gz
  macosDmg, // Miru_macos_1.7.5.dmg
  androidApk, // Miru_android_1.7.5.apk
  ios, // iOS App
  unknown,
}

/// 更新信息类
class UpdateInfo {
  final String version;
  final String description;
  final String downloadUrl;
  final String releaseNotes;
  final String publishedAt;
  final InstallationType? installationType;
  final List<InstallationType> availableInstallationTypes;
  final List<dynamic> assets;

  UpdateInfo({
    required this.version,
    required this.description,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.publishedAt,
    this.installationType,
    this.availableInstallationTypes = const [],
    this.assets = const [],
  });

  /// 获取默认的安装类型（第一个可用类型）
  InstallationType get recommendedInstallationType {
    if (availableInstallationTypes.isNotEmpty) {
      return availableInstallationTypes.first;
    }
    return installationType ?? InstallationType.unknown;
  }
}

Map<String, dynamic>? getUpdateAssetForType(
    List<dynamic> assets, InstallationType type) {
  final patterns = getUpdateFilePatterns(type).map((p) => p.toLowerCase());

  try {
    final asset = assets.cast<Map<String, dynamic>>().firstWhere((asset) {
      final name = (asset['name'] as String?)?.toLowerCase() ?? '';
      return patterns.every((pattern) => name.contains(pattern));
    });
    return asset;
  } catch (_) {
    return null;
  }
}

String getUpdateDownloadUrlFromAsset(Map<String, dynamic>? asset) {
  if (asset == null) {
    return '';
  }
  // 只信任 GitHub API 的 browser_download_url；不消费镜像响应里
  // 可能被注入的 mirror_download_url 等非标字段——那等于允许被篡改的
  // 元数据把下载重定向到任意地址，绕开可信镜像前缀
  // （updateDownloadMirrorPrefixes）。镜像需求已由 _downloadUrlCandidates
  // 用显式前缀实现，非标字段没有任何正当用途。
  return asset['browser_download_url'] as String? ?? '';
}

/// 取 Release 资产的 sha256 digest（GitHub API 均带 `sha256:` 前缀）。
/// 返回空串表示该资产未提供 digest，调用方应按「跳过校验」处理，
/// 而不是拿空串与实际哈希比较（那会把「无校验」变成「必失败」）。
String getUpdateFileHashFromAsset(Map<String, dynamic> asset) {
  final digest = asset['digest'] as String? ?? '';
  if (digest.isNotEmpty && digest.startsWith('sha256:')) {
    return digest.substring(7);
  }
  return '';
}

List<String> getUpdateFilePatterns(InstallationType installationType) {
  switch (installationType) {
    case InstallationType.windowsMsix:
      return ['windows', '.msix'];
    case InstallationType.windowsPortable:
      return ['windows', '.zip'];
    case InstallationType.macosDmg:
      return ['macos', '.dmg'];
    case InstallationType.androidApk:
      return ['android', '.apk'];
    case InstallationType.linuxDeb:
    case InstallationType.linuxTar:
    case InstallationType.ios:
    case InstallationType.unknown:
      return [];
  }
}

class AutoUpdater {
  static final AutoUpdater _instance = AutoUpdater._internal();

  factory AutoUpdater() => _instance;

  AutoUpdater._internal();

  final DownloadHttpClient _downloadClient = DownloadHttpClient.instance;

  /// 会话级去重：避免自动检查在同一进程内重复弹窗
  /// （引导页与主页面都接线了启动检查，极端时序下可能双触发）。
  bool _autoDialogShownThisSession = false;

  /// 检测所有可能的安装类型
  Future<List<InstallationType>> _detectAvailableInstallationTypes() async {
    List<InstallationType> availableTypes = [];

    try {
      if (Platform.isWindows) {
        // Windows 平台支持 MSIX 和 ZIP 便携版
        availableTypes.add(InstallationType.windowsMsix);
        availableTypes.add(InstallationType.windowsPortable);
      } else if (Platform.isLinux) {
        // Linux 平台支持 DEB 和 TAR.GZ
        availableTypes.add(InstallationType.linuxDeb);
        availableTypes.add(InstallationType.linuxTar);
      } else if (Platform.isMacOS) {
        // macOS 平台支持 DMG
        availableTypes.add(InstallationType.macosDmg);
      } else if (Platform.isIOS) {
        // iOS 平台通过 Github
        availableTypes.add(InstallationType.ios);
      } else if (Platform.isAndroid) {
        // Android 平台支持 APK
        availableTypes.add(InstallationType.androidApk);
      }
    } catch (e) {
      MiruLogger().w('Update: detect installation types failed', error: e);
    }

    if (availableTypes.isEmpty) {
      availableTypes.add(InstallationType.unknown);
    }

    return availableTypes;
  }

  /// 检查是否有新版本可用
  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final data = await _latestRelease();

      final tagName = data['tag_name'];
      if (tagName is! String || tagName.isEmpty) {
        throw Exception('无效的响应数据');
      }

      final remoteVersion = tagName;
      final currentVersion = ApiEndpoints.version;

      if (needUpdate(currentVersion, remoteVersion)) {
        final availableTypes = await _detectAvailableInstallationTypes();

        return UpdateInfo(
          version: remoteVersion,
          description: data['body'] is String
              ? data['body'] as String
              : '发现新版本',
          downloadUrl: '',
          // 将在用户选择安装类型后填充
          releaseNotes: data['html_url'] is String
              ? data['html_url'] as String
              : '',
          publishedAt: data['published_at'] is String
              ? data['published_at'] as String
              : '',
          installationType: availableTypes.first,
          // 保持兼容性
          availableInstallationTypes: availableTypes,
          assets: data['assets'] is List ? data['assets'] as List : const [],
        );
      }

      return null;
    } catch (e) {
      MiruLogger().e('Update: check for updates failed', error: e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _latestRelease() async {
    // 优先请求 GitHub Releases（Miru 自己的仓库），失败后降级到镜像源。
    // 每源限时：直连被墙时 connect 阶段可能挂十几秒，
    // 没有外层兜底的话弹窗会迟到半分钟。
    final sources = [ApiEndpoints.latestApp, ApiEndpoints.latestAppMirror];
    Object? lastError;
    for (final source in sources) {
      try {
        final raw = await _downloadClient
            .getPlain(
              source,
              receiveTimeout: const Duration(seconds: 8),
            )
            .timeout(const Duration(seconds: 10));
        final data = json.decode(raw);
        if (data is! Map) {
          throw Exception('Invalid update response');
        }
        return Map<String, dynamic>.from(data);
      } catch (e) {
        lastError = e;
        MiruLogger().w('Update: failed to fetch release from $source',
            error: e);
      }
    }
    throw lastError ?? Exception('All update sources failed');
  }

  /// 自动检查更新（仅在启用自动更新时）。
  ///
  /// 弹窗前双重静默判定：会话去重（热重启不重复弹）+
  /// 用户「忽略此版本」（出现更新的版本号后自动恢复提醒）。
  Future<void> autoCheckForUpdates() async {
    if (_autoDialogShownThisSession) return;
    final autoUpdate = GStorage.getSetting(SettingsKeys.autoUpdate);
    if (!autoUpdate) return;

    try {
      final updateInfo = await checkForUpdates();
      if (updateInfo == null) return;
      final ignored =
          GStorage.getSetting(SettingsKeys.updateIgnoredVersion);
      if (ignored.isNotEmpty && ignored == updateInfo.version) {
        return;
      }
      _autoDialogShownThisSession = true;
      _showUpdateDialog(updateInfo, isAutoCheck: true);
    } catch (e) {
      // 自动检查失败时不显示错误
      MiruLogger().w('Update: auto check for updates failed', error: e);
    }
  }

  /// 手动检查更新
  Future<void> manualCheckForUpdates() async {
    try {
      final updateInfo = await checkForUpdates();
      if (updateInfo != null) {
        _showUpdateDialog(updateInfo, isAutoCheck: false);
      } else {
        MiruDialog.showToast(message: '当前已经是最新版本！');
      }
    } catch (e) {
      MiruDialog.showToast(message: '检查更新失败');
    }
  }

  /// 显示更新对话框（液态玻璃风格，与公告弹窗同一视觉语言）。
  void _showUpdateDialog(UpdateInfo updateInfo, {bool isAutoCheck = false}) {
    MiruDialog.show(
      clickMaskDismiss: false,
      builder: (context) {
        return UpdateDialog(
          version: updateInfo.version,
          description: stripMarkdown(updateInfo.description),
          publishedAt: updateInfo.publishedAt.isEmpty
              ? ''
              : formatDate(updateInfo.publishedAt),
          onUpdate: () {
            // 直接使用第一个可用的安装类型（本应用实际只发 Android APK）；
            // 没有可用类型（iOS/Linux）时由 _downloadUpdateWithType 转跳发布页。
            if (updateInfo.availableInstallationTypes.isNotEmpty) {
              _downloadUpdateWithType(
                  updateInfo, updateInfo.availableInstallationTypes.first);
            } else {
              _openReleasePage(updateInfo);
            }
          },
          onOpenPage: () => _openReleasePage(updateInfo),
          onIgnore: isAutoCheck
              ? () {
                  GStorage.putSetting(
                      SettingsKeys.updateIgnoredVersion, updateInfo.version);
                  MiruDialog.showToast(
                      message: '已忽略 ${updateInfo.version}，出现新版本后会再次提醒');
                }
              : null,
        );
      },
    );
  }

  /// 浏览器打开 Release 发布页。
  void _openReleasePage(UpdateInfo updateInfo) {
    final url = updateInfo.releaseNotes.isNotEmpty
        ? updateInfo.releaseNotes
        : ApiEndpoints.projectUrl;
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// 获取安装类型的描述
  String _getInstallationTypeDescription(InstallationType type) {
    switch (type) {
      case InstallationType.windowsMsix:
        return 'Windows MSIX 包';
      case InstallationType.windowsPortable:
        return 'Windows 便携版 (ZIP)';
      case InstallationType.linuxDeb:
        return 'Linux DEB 包';
      case InstallationType.linuxTar:
        return 'Linux TAR 包';
      case InstallationType.macosDmg:
        return 'macOS DMG 镜像';
      case InstallationType.androidApk:
        return 'Android APK';
      case InstallationType.ios:
        return 'iOS ipa';
      case InstallationType.unknown:
        return '未知安装类型';
    }
  }

  /// 根据选择的类型下载更新
  Future<void> _downloadUpdateWithType(
      UpdateInfo updateInfo, InstallationType selectedType) async {
    try {
      // iOS 和 Linux 直接跳转到 Release 页面
      if (selectedType == InstallationType.ios ||
          selectedType == InstallationType.linuxDeb ||
          selectedType == InstallationType.linuxTar) {
        String releaseUrl = updateInfo.releaseNotes;
        if (releaseUrl.isEmpty) {
          releaseUrl = ApiEndpoints.latestApp;
        }
        launchUrl(Uri.parse(releaseUrl), mode: LaunchMode.externalApplication);
        return;
      }

      final asset = getUpdateAssetForType(updateInfo.assets, selectedType);
      final downloadUrl = getUpdateDownloadUrlFromAsset(asset);
      if (asset == null || downloadUrl.isEmpty) {
        MiruDialog.showToast(
            message:
                '没有找到 ${_getInstallationTypeDescription(selectedType)} 的下载链接');
        return;
      }

      final expectedHash = getUpdateFileHashFromAsset(asset);

      // 创建一个临时的 UpdateInfo 对象用于下载
      final downloadInfo = UpdateInfo(
        version: updateInfo.version,
        description: updateInfo.description,
        downloadUrl: downloadUrl,
        releaseNotes: updateInfo.releaseNotes,
        publishedAt: updateInfo.publishedAt,
        installationType: selectedType,
        availableInstallationTypes: [selectedType],
        assets: updateInfo.assets,
      );

      _downloadUpdate(downloadInfo, expectedHash);
    } catch (e) {
      MiruDialog.showToast(message: '下载失败: ${e.toString()}');
      MiruLogger().e('Update: download update failed', error: e);
    }
  }

  /// 下载更新
  Future<void> _downloadUpdate(
      UpdateInfo updateInfo, String expectedHash) async {
    if (updateInfo.downloadUrl.isEmpty) {
      MiruDialog.showToast(message: '没有找到合适的下载链接');
      return;
    }

    // 显示下载进度对话框
    MiruDialog.show(
      clickMaskDismiss: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('正在下载更新'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: _downloadProgress,
                builder: (context, value, child) {
                  return Column(
                    children: [
                      LinearProgressIndicator(value: value),
                      const SizedBox(height: 8),
                      Text('${(value * 100).toStringAsFixed(1)}%'),
                    ],
                  );
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _cancelDownload();
                MiruDialog.dismiss();
              },
              child: const Text('取消'),
            ),
          ],
        );
      },
    );

    try {
      final downloadPath = await _downloadFile(
          updateInfo.downloadUrl, updateInfo.version, expectedHash);

      // 不自动关闭对话框，而是显示下载完成状态
      _showDownloadCompleteDialog(downloadPath, updateInfo);
    } catch (e) {
      MiruDialog.dismiss();

      // 显示详细的错误信息
      final msg = e.toString();
      String errorMessage = '下载失败';
      if (msg.contains('Permission denied') ||
          msg.contains('Operation not permitted')) {
        errorMessage = '权限不足，文件已保存到应用临时目录';
      } else if (msg.contains('No space left')) {
        errorMessage = '磁盘空间不足';
      } else if (msg.contains('网络超时') ||
          msg.contains('timeout') ||
          msg.contains('TimeoutException')) {
        errorMessage = '网络超时，请检查网络后重试';
      } else if (msg.contains('网络连接') ||
          msg.contains('Network') ||
          msg.contains('Connection')) {
        errorMessage = '网络连接错误，请检查网络后重试';
      } else if (msg.contains('文件完整性验证失败')) {
        errorMessage = '文件完整性验证失败，可能是网络传输错误';
      }

      MiruDialog.show(
        builder: (context) {
          return AlertDialog(
            title: const Text('下载失败'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(errorMessage),
                const SizedBox(height: 8),
                Text(
                  '错误详情: $e',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => MiruDialog.dismiss(),
                child: const Text('确定'),
              ),
              TextButton(
                onPressed: () {
                  MiruDialog.dismiss();
                  // 浏览器下载：应用内持续失败时的最终兑底
                  _openReleasePage(updateInfo);
                },
                child: const Text('浏览器下载'),
              ),
              TextButton(
                onPressed: () {
                  MiruDialog.dismiss();
                  // 重新尝试下载
                  _downloadUpdate(updateInfo, expectedHash);
                },
                child: const Text('重试'),
              ),
            ],
          );
        },
      );

      MiruLogger().e('Update: download update failed', error: e);
    }
  }

  final ValueNotifier<double> _downloadProgress = ValueNotifier(0.0);
  CancelToken? _cancelToken;

  void _cancelDownload() {
    _cancelToken?.cancel();
  }

  /// 显示下载完成对话框
  void _showDownloadCompleteDialog(String filePath, UpdateInfo updateInfo) {
    // 替换当前的下载进度对话框内容
    MiruDialog.dismiss();

    MiruDialog.show(
      builder: (context) {
        return AlertDialog(
          title: const Text('下载完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('新版本 ${updateInfo.version} 已下载完成'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                // 桌面端安装后进程退出；Android 只拉起系统安装器，
                // 应用本身不退出，文案不能误导用户。
                Platform.isAndroid
                    ? '点击「立即安装」后由系统安装器接管安装流程'
                    : '安装过程中应用将会退出',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '文件位置:',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      filePath,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => MiruDialog.dismiss(),
              child: Text(
                '稍后安装',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            if (isDesktop())
              TextButton(
                onPressed: () {
                  // 在文件管理器中显示文件
                  _revealInFileManager(filePath);
                },
                child: const Text('打开文件夹'),
              ),
            TextButton(
              onPressed: () {
                MiruDialog.dismiss();
                _installUpdate(
                    filePath, updateInfo.recommendedInstallationType);
              },
              child: const Text('立即安装'),
            ),
          ],
        );
      },
    );
  }

  /// 下载文件
  ///
  /// GitHub Releases 直连在国内基本不可达（连接被重置 / 长时间无响应），
  /// 因此下载前先并发探测「镜像 + 直连」的可达性（Range 0-0 小请求，
  /// 2.5 秒超时），谁先应答就用谁下载；探测全失败则按候选顺序硬试。
  /// 下载中途网络错误也会自动切换下一个候选源重试。
  ///
  /// 完整性链路：元数据（Release json）与 APK 允许来自不同源，
  /// 但只要元数据带 digest，这里就会对下载结果强制校验；
  /// _installUpdate 只会处理本方法校验通过后返回的文件，
  /// 因此 digest 校验是安装前的硬关口，镜像换源不会绕过它。
  Future<String> _downloadFile(
      String url, String version, String expectedHash) async {
    final fileName = _getFileNameFromUrl(url, version);

    // 统一使用临时目录
    final tempDir = await getTemporaryDirectory();
    final filePath = '${tempDir.path}/$fileName';
    final file = File(filePath);

    // 检查文件是否已存在
    if (await file.exists()) {
      try {
        //使用哈希验证文件完整性
        final localHash = await _sha256File(file);
        // 资产未提供 digest 时无法验证：跳过校验直接复用本地文件
        // （重新下载同样无法验证，只会白耗一次流量）。
        if (expectedHash.isEmpty || localHash == expectedHash) {
          // 文件已存在且哈希匹配，直接返回
          MiruLogger().i(
              'Update: file already exists and hash verified, skipping download: $filePath');
          _downloadProgress.value = 1.0;
          return filePath;
        } else {
          // 文件存在但哈希不匹配，删除后重新下载
          MiruLogger().i(
              'Update: file hash mismatch detected (local: $localHash, expected: $expectedHash), deleting and re-downloading');
          await file.delete();
        }
      } catch (e) {
        // 验证过程中出错，删除文件重新下载
        MiruLogger().w(
            'Update: file verification failed, deleting and re-downloading',
            error: e);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }

    final candidates = _downloadUrlCandidates(url);
    final ranked = await _rankDownloadCandidates(candidates);

    Object? lastError;
    for (final candidate in ranked) {
      _cancelToken = CancelToken();
      _downloadProgress.value = 0.0;
      try {
        await _downloadClient.download(
          candidate,
          filePath,
          cancelToken: _cancelToken,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              _downloadProgress.value = received / total;
            }
          },
        );

        // 下载完成后验证文件哈希（安装前的强制关口：换源重试不会
        // 跳过这一步，见方法注释）。
        final downloadedHash = await _sha256File(file);
        if (expectedHash.isNotEmpty && downloadedHash != expectedHash) {
          // 哈希不匹配，删除文件并抛出异常
          await file.delete();
          throw Exception(
              '文件完整性验证失败: 期望 $expectedHash，实际 $downloadedHash');
        }
        if (expectedHash.isEmpty) {
          MiruLogger().w(
              'Update: asset has no sha256 digest, skip integrity verification');
        }
        MiruLogger()
            .i('Update: file downloaded from $candidate and hash verified');
        return filePath;
      } catch (e) {
        // 用户主动取消不换源，直接抛出
        if (_cancelToken?.isCancelled ?? false) {
          rethrow;
        }
        lastError = e;
        MiruLogger().w('Update: download failed from $candidate', error: e);
        // 清掉半成品，换下一个源重试
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
    }
    throw lastError ?? Exception('所有下载源均不可用');
  }

  /// 构造下载候选地址：镜像在前，原始直连在后。
  List<String> _downloadUrlCandidates(String url) {
    final candidates = <String>[
      for (final prefix in ApiEndpoints.updateDownloadMirrorPrefixes)
        if (!url.startsWith(prefix)) '$prefix$url',
      url,
    ];
    return candidates;
  }

  /// 并发探测候选地址可达性，返回按响应速度排序的列表。
  ///
  /// 用 `Range: bytes=0-0` 探测（响应 206/200 即视为可用，仅需几字节
  /// 流量），单源 2.5 秒超时。全部失败时返回原始顺序（硬试一轮）。
  Future<List<String>> _rankDownloadCandidates(List<String> candidates) async {
    if (candidates.length <= 1) return candidates;
    try {
      final results = await Future.wait(
        candidates.map((candidate) async {
          final stopwatch = Stopwatch()..start();
          try {
            await _downloadClient.getPlain(
              candidate,
              headers: const {'Range': 'bytes=0-0'},
              receiveTimeout: const Duration(milliseconds: 2500),
            );
            return (candidate, stopwatch.elapsedMilliseconds);
          } catch (_) {
            return (candidate, -1);
          }
        }),
      );
      final reachable = results
          .where((entry) => entry.$2 >= 0)
          .toList()
        ..sort((a, b) => a.$2.compareTo(b.$2));
      if (reachable.isEmpty) {
        return candidates;
      }
      // 可达的按速度排前，不可达的保留在后面作最后尝试
      final ranked = [
        for (final entry in reachable) entry.$1,
        for (final entry in results.where((e) => e.$2 < 0)) entry.$1,
      ];
      MiruLogger().i(
          'Update: download mirror probe result: ${ranked.join(' -> ')}');
      return ranked;
    } catch (e) {
      MiruLogger()
          .w('Update: download mirror probe failed, fallback to direct',
              error: e);
      return candidates;
    }
  }

  /// 安装更新
  void _installUpdate(
      String filePath, InstallationType installationType) async {
    try {
      // 显示准备退出的提示（Android 不退出，只拉起系统安装器）
      MiruDialog.showToast(
          message: Platform.isAndroid
              ? '准备安装更新，正在拉起系统安装器...'
              : '准备安装更新，应用即将退出...');

      await Future.delayed(const Duration(seconds: 2));

      if (Platform.isWindows) {
        if (installationType == InstallationType.windowsMsix) {
          final Uri fileUri = Uri.file(filePath);
          if (await canLaunchUrl(fileUri)) {
            await launchUrl(fileUri);
          } else {
            throw 'Could not launch $fileUri';
          }
        } else {
          await Process.start('explorer.exe', [filePath], runInShell: true);
        }
        await Future.delayed(const Duration(seconds: 1));
        exit(0);
      } else if (Platform.isMacOS) {
        if (filePath.endsWith('.dmg')) {
          await Process.start('open', [filePath]);
          exit(0);
        }
      } else if (Platform.isAndroid) {
        final result = await OpenFilex.open(filePath);
        if (result.type != ResultType.done) {
          MiruDialog.showToast(message: '无法打开安装文件: ${result.message}');
          return;
        }
      }
    } catch (e) {
      MiruDialog.showToast(message: '启动安装程序失败: ${e.toString()}');
      MiruLogger().e('Update: launch installer failed', error: e);
    }
  }

  /// 在文件管理器中显示文件
  void _revealInFileManager(String filePath) async {
    try {
      final type = await FileSystemEntity.type(filePath);
      String targetDirOrFile;

      // 如果传入的本来就是目录则打开这个目录
      // 如果是文件则打开包含它的目录
      if (type == FileSystemEntityType.notFound) {
        MiruDialog.showToast(message: '文件或目录不存在');
        return;
      } else if (type == FileSystemEntityType.directory) {
        targetDirOrFile = filePath;
      } else {
        targetDirOrFile = File(filePath).parent.path;
      }

      if (Platform.isWindows) {
        if (type == FileSystemEntityType.file) {
          final arg = '/select,${filePath.replaceAll('/', r'\')}';
          await Process.start('explorer.exe', [arg], runInShell: true);
        } else {
          await Process.start(
              'explorer.exe', [targetDirOrFile.replaceAll('/', r'\')],
              runInShell: true);
        }
      } else if (Platform.isMacOS) {
        if (type == FileSystemEntityType.file) {
          await Process.start('open', ['-R', filePath]);
        } else {
          await Process.start('open', [targetDirOrFile]);
        }
      } else if (Platform.isLinux) {
        // 尝试打开包含文件的文件夹
        await Process.start('xdg-open', [targetDirOrFile]);
      } else {
        MiruDialog.showToast(message: '此平台不支持通过此方法打开文件管理器');
      }
    } catch (e) {
      MiruDialog.showToast(message: '无法打开文件管理器');
      MiruLogger().w('Update: reveal in file manager failed', error: e);
    } finally {
      try {
        // 确保对话框被关闭
        MiruDialog.dismiss();
      } catch (_) {}
    }
  }

  /// 从URL获取文件名
  String _getFileNameFromUrl(String url, String version) {
    final uri = Uri.parse(url);
    final fileName = uri.pathSegments.last;

    if (fileName.isNotEmpty) {
      return fileName;
    }

    // 回退方案
    String extension = '';
    if (Platform.isWindows) {
      extension = '.msix';
    } else if (Platform.isMacOS) {
      extension = '.dmg';
    } else if (Platform.isLinux) {
      extension = '.deb';
    } else if (Platform.isAndroid) {
      extension = '.apk';
    }
    return 'Miru-$version$extension';
  }
}

/// 收集分块哈希最终结果的极简 Sink。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 分块流式 sha256：更新包动辄几十 MB，整文件读入内存会在低端机上
/// 造成同等大小的内存尖峰，这里按流分块喂给哈希器。
Future<String> _sha256File(File file) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return sink.value.toString();
}
