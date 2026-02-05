import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/services/bridge/bridge_client.dart';
import 'package:rxdart/rxdart.dart';

/// Scale implementation that talks to DecentBridge over HTTP/WebSocket.
class BridgeScale implements Scale {
  final BridgeClient _client;
  final String _deviceId;
  final String _name;
  final _log = Logger('BridgeScale');

  final BehaviorSubject<ScaleSnapshot> _snapshotSubject =
      BehaviorSubject<ScaleSnapshot>();
  final BehaviorSubject<ConnectionState> _connectionStateSubject =
      BehaviorSubject.seeded(ConnectionState.disconnected);

  StreamSubscription? _snapshotSubscription;

  BridgeScale({
    required BridgeClient client,
    required String deviceId,
    String name = 'Scale (Bridge)',
  })  : _client = client,
        _deviceId = deviceId,
        _name = name;

  @override
  String get deviceId => _deviceId;

  @override
  String get name => _name;

  @override
  DeviceType get type => DeviceType.scale;

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateSubject.stream;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshotSubject.stream;

  @override
  Future<void> onConnect() async {
    _log.info('Connecting to scale via Bridge');
    _connectionStateSubject.add(ConnectionState.connecting);

    try {
      _snapshotSubscription = _client
          .connectWebSocket('/ws/v1/scale/snapshot')
          .listen(
        (json) {
          try {
            _snapshotSubject.add(ScaleSnapshot.fromJson(json));
          } catch (e) {
            _log.warning('Failed to parse scale snapshot: $e');
          }
        },
      );

      _connectionStateSubject.add(ConnectionState.connected);
      _log.info('Connected to scale via Bridge');
    } catch (e) {
      _log.severe('Failed to connect to scale via Bridge: $e');
      _connectionStateSubject.add(ConnectionState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _log.info('Disconnecting scale via Bridge');
    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    _client.disconnectWebSocket('/ws/v1/scale/snapshot');
    _connectionStateSubject.add(ConnectionState.disconnected);
    try {
      await _client.put('/api/v1/scale/disconnect');
    } catch (e) {
      _log.warning('Failed to disconnect scale on bridge: $e');
    }
  }

  @override
  Future<void> tare() async {
    _log.fine('Taring scale');
    await _client.put('/api/v1/scale/tare');
  }

  @override
  Future<void> sleepDisplay() async {
    // DecentBridge doesn't have a separate sleep command; disconnect instead
    await _client.put('/api/v1/scale/disconnect');
  }

  @override
  Future<void> wakeDisplay() async {
    // No-op — scale will reconnect when DecentBridge scans
  }
}
