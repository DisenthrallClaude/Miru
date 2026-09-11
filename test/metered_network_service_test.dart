import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru/services/network/metered_network_service.dart';

/// 计量网络服务单测（同步自上游 Kazumi 22f9ee1 的修复行为）：
/// - refresh 的显式首读修正「后台期间丢失的网络切换」（isMetered 陈旧 →
///   移动数据下 demuxer 缓存与 LocalMediaProxy 预取继续烧流量的根因）
/// - 生命周期 resumed 自动触发 refresh
/// - 换网窗口 wifi+mobile 并存按非计量归并
/// - none/vpn 等不可解析状态保持上次保护状态
/// - checkConnectivity 超时不抛异常且保留状态
/// - revision 守卫：网络事件先到时丢弃过期的显式首读
///
/// 通过 mock connectivity_plus 6.1.x 的原生通道注入状态与事件。
/// 用纯 test()（非 testWidgets）：真实异步链 + 真实 Timer（超时用例），
/// 与 catalog_flow_test 同模式。
const MethodChannel _kCheckChannel =
    MethodChannel('dev.fluttercommunity.plus/connectivity');
const EventChannel _kEventChannel =
    EventChannel('dev.fluttercommunity.plus/connectivity_status');

MockStreamHandlerEventSink? _sink;
List<String> _connectivity = ['wifi'];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _connectivity = ['wifi'];
    _sink = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _kCheckChannel,
      (call) async {
        if (call.method == 'check') return _connectivity;
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockStreamHandler(
      _kEventChannel,
      MockStreamHandler.inline(
        onListen: (_, sink) => _sink = sink,
        onCancel: (_) => _sink = null,
      ),
    );
    return MeteredNetworkService.debugResetForTest();
  });

  tearDown(() async {
    await MeteredNetworkService.debugResetForTest();
    debugDefaultTargetPlatformOverride = null;
    _sink = null;
  });

  group('MeteredNetworkService.refresh', () {
    test('显式首读修正后台期间丢失的网络切换', () async {
      _connectivity = ['wifi'];
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isFalse);

      // app 在后台期间 wifi → 移动数据：事件丢失（不向事件流注入），
      // 只有平台当前状态变了。旧实现（无显式首读）永远读不到。
      _connectivity = ['mobile'];
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isTrue,
          reason: '后台期间丢失的网络切换应被 refresh 的显式首读修正');
    });

    test('网络事件实时驱动状态', () async {
      await MeteredNetworkService.refresh();
      _sink?.success(['mobile']);
      await pumpEventQueue();
      expect(MeteredNetworkService.isMetered, isTrue);

      _sink?.success(['wifi']);
      await pumpEventQueue();
      expect(MeteredNetworkService.isMetered, isFalse);
    });

    test('换网窗口 wifi+mobile 并存按非计量归并', () async {
      await MeteredNetworkService.refresh();
      // Android 换网瞬间会同时上报 wifi 与 mobile。
      _sink?.success(['wifi', 'mobile']);
      await pumpEventQueue();
      expect(MeteredNetworkService.isMetered, isFalse);
    });

    test('不可解析的网络状态保持上次保护状态', () async {
      _connectivity = ['mobile'];
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isTrue);

      _connectivity = ['none'];
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isTrue,
          reason: 'none 不可解析时应保持计量保护');

      _connectivity = ['vpn'];
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isTrue,
          reason: '裸 vpn 不可解析时应保持计量保护');
    });

    test('checkConnectivity 无响应超时后保留状态且不抛异常', () async {
      _connectivity = ['mobile'];
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isTrue);

      final blocker = Completer<Object?>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _kCheckChannel,
        (call) async => call.method == 'check' ? blocker.future : null,
      );
      // 首读 3s 超时（真实 Timer），异常被吞、状态保留。
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isTrue,
          reason: '首读超时应保留上次状态');
    });

    test('网络事件先到时丢弃过期的显式首读', () async {
      _connectivity = ['mobile'];
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isTrue);

      // 一个在途 refresh：首读被挂起，稍后才返回切换前的旧状态。
      final lateReply = Completer<Object?>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _kCheckChannel,
        (call) async => call.method == 'check' ? lateReply.future : null,
      );
      final refreshing = MeteredNetworkService.refresh();
      await pumpEventQueue();

      // refresh 在途时事件先到：宣布切回 wifi。
      _sink?.success(['wifi']);
      await pumpEventQueue();
      expect(MeteredNetworkService.isMetered, isFalse);

      // 滞后的首读带着旧状态（mobile）返回，不得覆盖事件已写入的结果。
      lateReply.complete(['mobile']);
      await refreshing;
      await pumpEventQueue();
      expect(MeteredNetworkService.isMetered, isFalse,
          reason: '被网络事件取代的过期首读应被 revision 守卫丢弃');
    });
  });

  group('MeteredNetworkService.init', () {
    test('生命周期 resumed 自动刷新陈旧的计量状态', () async {
      _connectivity = ['wifi'];
      MeteredNetworkService.init();
      await pumpEventQueue();
      expect(MeteredNetworkService.isMetered, isFalse);

      // app 进后台（事件流不再投递）。
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // 后台期间 wifi → 移动数据切换，事件丢失。
      _connectivity = ['mobile'];
      // 回前台：生命周期守卫应触发 refresh 修正状态。
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(MeteredNetworkService.isMetered, isTrue,
          reason: 'resumed 应触发 refresh 修正后台期间的切换');
    });

    test('init 幂等：重复调用不抛异常且状态仍正确', () async {
      MeteredNetworkService.init();
      MeteredNetworkService.init();
      _connectivity = ['mobile'];
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(MeteredNetworkService.isMetered, isTrue);
    });
  });

  group('非移动平台', () {
    test('桌面平台 refresh 直接返回不建立订阅', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await MeteredNetworkService.refresh();
      expect(MeteredNetworkService.isMetered, isFalse);
    });
  });
}
