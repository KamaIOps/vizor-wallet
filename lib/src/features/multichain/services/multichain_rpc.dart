import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal HTTP helper for the multichain public endpoints.
///
/// Requests run on demand only. Each call tries the chain's endpoints in
/// order and fails over on network errors and 5xx responses. No API keys,
/// no shared identifiers, no ZEC data in any request (see the multichain
/// design disciplines in AGENTS.md).
class MultichainRpc {
  MultichainRpc({HttpClient? client})
    : _client = client ?? (HttpClient()..connectionTimeout = _timeout);

  static const _timeout = Duration(seconds: 15);
  final HttpClient _client;

  /// GET returning a JSON-decoded body (or raw string when [rawText]).
  Future<Object?> get(
    List<String> endpoints,
    String path, {
    bool rawText = false,
  }) {
    return _withFailover(endpoints, (base) async {
      final request = await _client.getUrl(Uri.parse('$base$path'));
      return _finish(request, rawText: rawText);
    });
  }

  /// POST with a JSON body, returning a JSON-decoded body.
  Future<Object?> postJson(
    List<String> endpoints,
    String path,
    Object body,
  ) {
    return _withFailover(endpoints, (base) async {
      final request = await _client.postUrl(Uri.parse('$base$path'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      return _finish(request);
    });
  }

  /// POST with a plain-text body (Esplora `/tx` broadcast), returning text.
  Future<Object?> postText(
    List<String> endpoints,
    String path,
    String body,
  ) {
    return _withFailover(endpoints, (base) async {
      final request = await _client.postUrl(Uri.parse('$base$path'));
      request.headers.contentType = ContentType.text;
      request.write(body);
      return _finish(request, rawText: true);
    });
  }

  /// JSON-RPC 2.0 call (EVM and Solana endpoints).
  Future<Object?> jsonRpc(
    List<String> endpoints,
    String method,
    List<Object?> params,
  ) async {
    final response = await postJson(endpoints, '', {
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params,
    });
    if (response is! Map<String, dynamic>) {
      throw MultichainRpcException('Malformed JSON-RPC response');
    }
    final error = response['error'];
    if (error != null) {
      final message = error is Map ? error['message'] : null;
      throw MultichainRpcException(
        message is String ? message : 'RPC error: $error',
      );
    }
    return response['result'];
  }

  Future<Object?> _finish(
    HttpClientRequest request, {
    bool rawText = false,
  }) async {
    final response = await request.close().timeout(_timeout);
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_timeout);
    if (response.statusCode >= 500) {
      throw _RetryableHttpException(response.statusCode, body);
    }
    if (response.statusCode >= 400) {
      throw MultichainRpcException(
        _compactError(body, response.statusCode),
      );
    }
    if (rawText) return body;
    if (body.isEmpty) return null;
    return jsonDecode(body);
  }

  Future<Object?> _withFailover(
    List<String> endpoints,
    Future<Object?> Function(String base) attempt,
  ) async {
    Object? lastError;
    for (final base in endpoints) {
      try {
        return await attempt(base);
      } on MultichainRpcException {
        rethrow; // 4xx / RPC-level errors are not endpoint failures.
      } catch (e) {
        lastError = e;
      }
    }
    throw MultichainRpcException(
      'All endpoints failed (${lastError ?? 'unknown error'})',
    );
  }

  static String _compactError(String body, int status) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return 'HTTP $status';
    return trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed;
  }

  void close() => _client.close(force: true);
}

class MultichainRpcException implements Exception {
  MultichainRpcException(this.message);
  final String message;

  @override
  String toString() => message;
}

class _RetryableHttpException implements Exception {
  _RetryableHttpException(this.status, this.body);
  final int status;
  final String body;

  @override
  String toString() => 'HTTP $status';
}
