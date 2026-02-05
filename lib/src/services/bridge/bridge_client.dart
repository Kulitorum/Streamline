import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class BridgeClient {
  final _log = Logger('BridgeClient');

  String httpBaseUrl;
  String wsBaseUrl;

  final http.Client _httpClient = http.Client();
  final Map<String, _WebSocketConnection> _wsConnections = {};

  BridgeClient({
    this.httpBaseUrl = 'http://localhost:8080',
    this.wsBaseUrl = 'ws://localhost:8081',
  });

  void updateUrls({required String httpBaseUrl, required String wsBaseUrl}) {
    this.httpBaseUrl = httpBaseUrl;
    this.wsBaseUrl = wsBaseUrl;
  }

  // ─── REST helpers ───

  Future<Map<String, dynamic>> get(String path) async {
    final url = Uri.parse('$httpBaseUrl$path');
    _log.fine('GET $url');
    final response = await _httpClient.get(url);
    _checkResponse(response);
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> getList(String path) async {
    final url = Uri.parse('$httpBaseUrl$path');
    _log.fine('GET (list) $url');
    final response = await _httpClient.get(url);
    _checkResponse(response);
    if (response.body.isEmpty) return [];
    return jsonDecode(response.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final url = Uri.parse('$httpBaseUrl$path');
    _log.fine('POST $url');
    final response = await _httpClient.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkResponse(response);
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> put(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final url = Uri.parse('$httpBaseUrl$path');
    _log.fine('PUT $url');
    final response = await _httpClient.put(
      url,
      headers: body != null ? {'Content-Type': 'application/json'} : null,
      body: body != null ? jsonEncode(body) : null,
    );
    _checkResponse(response);
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Check if the bridge is reachable.
  Future<bool> isReachable() async {
    try {
      final url = Uri.parse('$httpBaseUrl/api/v1/devices');
      final response = await _httpClient
          .get(url)
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void _checkResponse(http.Response response) {
    if (response.statusCode >= 400) {
      _log.warning(
        'HTTP ${response.statusCode}: ${response.body}',
      );
      throw BridgeHttpException(response.statusCode, response.body);
    }
  }

  // ─── WebSocket helpers ───

  /// Connect to a WebSocket channel and return a broadcast stream of parsed
  /// JSON maps. Automatically reconnects on disconnect with exponential
  /// backoff.
  Stream<Map<String, dynamic>> connectWebSocket(String path) {
    if (_wsConnections.containsKey(path)) {
      return _wsConnections[path]!.stream;
    }
    final conn = _WebSocketConnection(
      url: '$wsBaseUrl$path',
      log: _log,
    );
    _wsConnections[path] = conn;
    conn.connect();
    return conn.stream;
  }

  /// Disconnect a specific WebSocket channel.
  void disconnectWebSocket(String path) {
    _wsConnections[path]?.dispose();
    _wsConnections.remove(path);
  }

  /// Disconnect all WebSocket channels.
  void disconnectAllWebSockets() {
    for (final conn in _wsConnections.values) {
      conn.dispose();
    }
    _wsConnections.clear();
  }

  void dispose() {
    disconnectAllWebSockets();
    _httpClient.close();
  }
}

class BridgeHttpException implements Exception {
  final int statusCode;
  final String body;

  BridgeHttpException(this.statusCode, this.body);

  @override
  String toString() => 'BridgeHttpException($statusCode): $body';
}

/// Internal WebSocket connection with auto-reconnect.
class _WebSocketConnection {
  final String url;
  final Logger log;

  final BehaviorSubject<Map<String, dynamic>> _subject =
      BehaviorSubject<Map<String, dynamic>>();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  Stream<Map<String, dynamic>> get stream => _subject.stream;

  _WebSocketConnection({required this.url, required this.log});

  void connect() {
    if (_disposed) return;
    log.fine('WebSocket connecting: $url');
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _reconnectAttempt = 0;
      _subscription = _channel!.stream.listen(
        (data) {
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            _subject.add(json);
          } catch (e) {
            log.warning('WebSocket parse error on $url: $e');
          }
        },
        onError: (error) {
          log.warning('WebSocket error on $url: $error');
          _scheduleReconnect();
        },
        onDone: () {
          log.fine('WebSocket closed: $url');
          _scheduleReconnect();
        },
      );
    } catch (e) {
      log.warning('WebSocket connect failed: $url: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _subscription?.cancel();
    _channel?.sink.close().catchError((_) {});
    _channel = null;

    final delay = Duration(
      milliseconds: (500 * (1 << _reconnectAttempt)).clamp(500, 30000),
    );
    _reconnectAttempt++;
    log.fine('WebSocket reconnect in ${delay.inMilliseconds}ms: $url');
    _reconnectTimer = Timer(delay, connect);
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close().catchError((_) {});
    _subject.close();
  }
}
