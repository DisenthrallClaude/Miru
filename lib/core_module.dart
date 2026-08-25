import 'package:flutter_modular/flutter_modular.dart';
import 'package:miru/pages/collect/collect_controller.dart';
import 'package:miru/pages/download/download_controller.dart';
import 'package:miru/pages/history/history_controller.dart';
import 'package:miru/pages/my/my_controller.dart';
import 'package:miru/plugins/plugins_controller.dart';
import 'package:miru/repositories/collect_crud_repository.dart';
import 'package:miru/repositories/collect_repository.dart';
import 'package:miru/repositories/download_repository.dart';
import 'package:miru/repositories/history_repository.dart';
import 'package:miru/repositories/search_history_repository.dart';
import 'package:miru/services/download/download_manager.dart';
import 'package:miru/services/player/audio_controller.dart';
import 'package:miru/services/player/history_playback_service.dart';
import 'package:miru/services/shaders/shader_asset_service.dart';

/// Root-owned application data and cross-feature coordinators.
///
/// This module intentionally has no path, so its registrations live for the
/// whole application. Page and feature-local state belongs in route `provide`
/// callbacks or path-bearing modules instead.
final coreModule = createModule(
  register: (c) {
    c
      // Repository layer.
      ..addSingleton<ICollectRepository>(CollectRepository.new)
      ..addSingleton<ISearchHistoryRepository>(SearchHistoryRepository.new)
      ..addSingleton<ICollectCrudRepository>(CollectCrudRepository.new)
      ..addSingleton<IHistoryRepository>(HistoryRepository.new)
      ..addSingleton<IDownloadRepository>(DownloadRepository.new)
      // Service layer.
      ..addSingleton<IDownloadManager>(DownloadManager.new)
      ..addSingleton<AudioController>(AudioController.new)
      ..addSingleton<HistoryPlaybackService>(HistoryPlaybackService.new)
      ..addSingleton<ShaderAssetService>(ShaderAssetService.new)
      // Cross-feature state and coordinators.
      ..addSingleton<PluginsController>(PluginsController.new)
      ..addSingleton<CollectController>(CollectController.new)
      ..addSingleton<HistoryController>(HistoryController.new)
      ..addSingleton<MyController>(MyController.new)
      ..addSingleton<DownloadController>(DownloadController.new);
  },
);
