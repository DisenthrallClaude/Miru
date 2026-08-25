import 'dart:convert';

/// 规则分享链接协议前缀：Miru 独立身份。
///
/// 解析端同时兼容旧上游的 `kazumi://` 前缀，
/// 保证社区里已分发的存量规则链接可以继续导入。
const String ruleShareScheme = 'miru://';

String jsonToMiruBase64(String jsonStr) {
  final base64Str = base64Encode(utf8.encode(jsonStr));
  return '$ruleShareScheme$base64Str';
}

String miruBase64ToJson(String shareLink) {
  final input = shareLink.trim();
  final schemeMatch = RegExp(
    r'^(?:miru|kazumi):(?://)?',
    caseSensitive: false,
  ).firstMatch(input);
  if (schemeMatch == null) {
    throw const FormatException('Invalid Miru rule link');
  }

  var payload = input.substring(schemeMatch.end);
  try {
    payload = Uri.decodeComponent(payload);
  } on FormatException {
    throw const FormatException('Invalid encoding in Miru rule link');
  }
  payload = payload.replaceAll(RegExp(r'\s'), '');
  if (payload.isEmpty) {
    throw const FormatException('Miru rule link is empty');
  }

  // Accept both standard and URL-safe Base64, with or without padding. Links
  // are frequently wrapped by chat applications or percent-encoded by URI
  // handlers before they reach the import dialog.
  final normalized = base64.normalize(
    payload.replaceAll('-', '+').replaceAll('_', '/'),
  );
  try {
    return utf8.decode(base64.decode(normalized));
  } on FormatException {
    throw const FormatException('Invalid Miru rule link payload');
  }
}
