import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/media_kit.dart';
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:miru/services/logging/logger.dart';

/// 一帧 BGRA（bgr0）像素。
class GrabbedFrame {
  const GrabbedFrame(this.bytes, this.width, this.height, this.stride);
  final Uint8List bytes;
  final int width;
  final int height;
  final int stride;
}

/// 为去广告画面识别取帧（v1.8.0）。
///
/// ## 为什么不直接用 `Player.safeScreenshot`
/// media_kit 的截图固定走 `screenshot-raw video`：mpv 需要把**解码帧**下载
/// 回内存。Android 默认 `hwdec=auto-safe` → mediacodec 直通，帧在 GPU 表面上，
/// 下载不受支持，结果恒为 null —— CI（run 39943242315）里片头水印检测
/// 三源全部 `first=null`，FQDM 的「45079.com 赞助」水印因此没有被跳过。
///
/// `screenshot-raw window` 由 VO（gpu/gpu-next）把**已渲染的画面**读回，
/// 与解码方式无关，且尺寸是显示纹理尺寸（更小、更省）。这里先试 window，
/// 失败再退回 video（软解/拷贝模式下 video 更精确）。
abstract final class MpvFrameGrabber {
  static String? _lastMode;

  static Future<GrabbedFrame?> grab(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return null;
    int ctx;
    String lib;
    try {
      ctx = await platform.handle;
      lib = NativeLibrary.path;
    } catch (_) {
      return null;
    }
    for (final mode in const ['window', 'video']) {
      GrabbedFrame? f;
      try {
        f = await Isolate.run(() => _screenshotRaw(ctx, lib, mode));
      } catch (e) {
        f = null;
      }
      if (f != null) {
        if (_lastMode != mode) {
          _lastMode = mode;
          MiruLogger().i('MIRU_AD grab mode=$mode ${f.width}x${f.height}');
        }
        return f;
      }
    }
    if (_lastMode != 'none') {
      _lastMode = 'none';
      MiruLogger().w('MIRU_AD grab failed (window & video)');
    }
    return null;
  }
}

GrabbedFrame? _screenshotRaw(int ctxAddress, String lib, String mode) {
  final mpv = generated.MPV(DynamicLibrary.open(lib));
  final ctx = Pointer<generated.mpv_handle>.fromAddress(ctxAddress);
  final args = ['screenshot-raw', mode];
  final result = calloc<generated.mpv_node>();
  final pointers = <Pointer<Utf8>>[];
  final arr = calloc<Pointer<Utf8>>(args.length + 1);
  try {
    for (var i = 0; i < args.length; i++) {
      final p = args[i].toNativeUtf8();
      pointers.add(p);
      (arr + i).value = p;
    }
    final rc = mpv.mpv_command_ret(ctx, arr.cast(), result);
    if (rc < 0 ||
        result.ref.format != generated.mpv_format.MPV_FORMAT_NODE_MAP) {
      return null;
    }
    int? w, h, stride;
    Uint8List? bytes;
    final map = result.ref.u.list;
    for (var i = 0; i < map.ref.num; i++) {
      final key = map.ref.keys[i].cast<Utf8>().toDartString();
      final value = map.ref.values[i];
      if (value.format == generated.mpv_format.MPV_FORMAT_INT64) {
        switch (key) {
          case 'w':
            w = value.u.int64;
          case 'h':
            h = value.u.int64;
          case 'stride':
            stride = value.u.int64;
        }
      } else if (value.format == generated.mpv_format.MPV_FORMAT_BYTE_ARRAY &&
          key == 'data') {
        final data = value.u.ba.ref.data.cast<Uint8>();
        bytes = Uint8List.fromList(data.asTypedList(value.u.ba.ref.size));
      }
    }
    if (w == null || h == null || stride == null || bytes == null) return null;
    if (w <= 0 || h <= 0 || stride < w * 4) return null;
    if (bytes.length < stride * (h - 1) + w * 4) return null;
    return GrabbedFrame(bytes, w, h, stride);
  } finally {
    for (final p in pointers) {
      calloc.free(p);
    }
    calloc.free(arr);
    mpv.mpv_free_node_contents(result);
    calloc.free(result);
  }
}
