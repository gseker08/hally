import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/api/api_client.dart';
import 'package:hally/core/auth/token_storage.dart';

class _MemoryTokens implements TokenStorage {
  StoredTokens? tokens = const StoredTokens(accessToken: 'old', refreshToken: 'r1');
  var cleared = false;

  @override
  Future<StoredTokens?> read() async => tokens;

  @override
  Future<void> write(StoredTokens t) async => tokens = t;

  @override
  Future<void> clear() async {
    cleared = true;
    tokens = null;
  }
}

/// Answers 401 to the first upload, then 201 once the refreshed token is sent.
/// Reads the whole request body like a real transport, so a finalized FormData would fail.
class _Adapter implements HttpClientAdapter {
  final uploads = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (requestStream != null) await requestStream.drain<void>();
    ResponseBody json(int status, Object body) =>
        ResponseBody.fromString(jsonEncode(body), status, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});

    if (options.path == '/api/v1/auth/refresh') return json(200, {'accessToken': 'new', 'refreshToken': 'r2'});
    final auth = options.headers['Authorization'] as String?;
    uploads.add(auth ?? '');
    return auth == 'Bearer new' ? json(201, {'id': 'c1'}) : json(401, {'code': 'auth.unauthorized'});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('a multipart upload that gets 401 is retried with a fresh body after the token refresh', () async {
    final tokens = _MemoryTokens();
    final adapter = _Adapter();
    final client = ApiClient(tokens, dio: Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter);

    final res = await client.dio
        .post<Map<String, dynamic>>(
          '/api/v1/families/f1/captures',
          data: FormData.fromMap({'source': 'Gallery', 'file': MultipartFile.fromBytes([1, 2, 3], filename: 'a.png')}),
        )
        .timeout(const Duration(seconds: 5));

    expect(res.statusCode, 201);
    expect(adapter.uploads, ['Bearer old', 'Bearer new']);
    expect(tokens.tokens?.refreshToken, 'r2');
    expect(tokens.cleared, isFalse);
  });
}
