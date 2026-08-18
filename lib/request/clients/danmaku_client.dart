import 'package:dio/dio.dart';
import 'package:kazumi/request/config/danmaku_api_config.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:kazumi/utils/crypto.dart';

class DanmakuClient {
  DanmakuClient._();

  static final DanmakuClient instance = DanmakuClient._();

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic> headers = const {},
    CancelToken? cancelToken,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse(url);
    final requestHeaders = <String, dynamic>{
      'user-agent': getRandomUA(),
      'referer': '',
      ...headers,
    };
    // 官方弹弹play 必须带签名；自定义兼容接口（如 danmu_api）不认这套头。
    if (DanmakuApiConfig.shouldSignRequest(url)) {
      requestHeaders.addAll({
        'X-Auth': 1,
        'X-AppId': dandanCredentials['id'],
        'X-Timestamp': timestamp,
        'X-Signature': generateDandanSignature(uri.path, timestamp),
      });
    }

    try {
      final response = await DioFactory.apiDio.get(
        url,
        queryParameters: queryParameters,
        options: Options(headers: requestHeaders),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }
}
