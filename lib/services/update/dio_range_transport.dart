import 'package:dio/dio.dart';
import 'package:miru/request/core/dio_factory.dart';
import 'package:miru/services/update/mirror_downloader.dart';

/// 基于全局下载 Dio 的 [RangeTransport]：继承应用的代理设置与
/// 补充根证书（Android ≤13 缺新根时 GitHub/镜像握手失败的问题已在
/// DioFactory 层修复），跟随镜像的 302 跳转。
class DioRangeTransport implements RangeTransport {
  DioRangeTransport({Dio? dio}) : _dio = dio ?? DioFactory.downloadDio;

  final Dio _dio;

  @override
  Future<RangeResponse> get(String url,
      {int? start, int? end, RangeCancel? cancel}) async {
    final token = CancelToken();
    cancel?.onCancel(() {
      if (!token.isCancelled) token.cancel();
    });
    final resp = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        maxRedirects: 8,
        // 每块单独计时：响应头 8 秒内不来就算这个源卡死。
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          if (start != null)
            'Range': 'bytes=$start-${end == null ? '' : end.toString()}',
          'Accept-Encoding': 'identity',
        },
        validateStatus: (s) => s != null && s >= 200 && s < 400,
      ),
      cancelToken: token,
    );
    final body = resp.data!;
    return RangeResponse(
      statusCode: resp.statusCode ?? 0,
      body: body.stream.map((u) => u),
      contentLength:
          int.tryParse(resp.headers.value('content-length') ?? ''),
      contentRange: resp.headers.value('content-range'),
    );
  }
}
