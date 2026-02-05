import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/bridge/bridge_client.dart';
import 'package:rxdart/rxdart.dart';

/// Maps between DecentBridge state names and ReaPrime MachineState enum.
class _StateMapping {
  static const Map<String, MachineState> _fromBridge = {
    'sleep': MachineState.sleeping,
    'idle': MachineState.idle,
    'espresso': MachineState.espresso,
    'steam': MachineState.steam,
    'water': MachineState.hotWater,
    'flush': MachineState.flush,
    'heating': MachineState.heating,
    'busy': MachineState.busy,
    'descaling': MachineState.descaling,
    'cleaning': MachineState.cleaning,
    'sleeping': MachineState.sleeping,
    'hotWater': MachineState.hotWater,
    'booting': MachineState.booting,
    'preheating': MachineState.preheating,
    'steamRinse': MachineState.steamRinse,
    'skipStep': MachineState.skipStep,
    'calibration': MachineState.calibration,
    'selfTest': MachineState.selfTest,
    'airPurge': MachineState.airPurge,
    'needsWater': MachineState.needsWater,
    'error': MachineState.error,
    'fwUpgrade': MachineState.fwUpgrade,
  };

  static const Map<MachineState, String> _toBridge = {
    MachineState.sleeping: 'sleep',
    MachineState.hotWater: 'water',
    MachineState.idle: 'idle',
    MachineState.espresso: 'espresso',
    MachineState.steam: 'steam',
    MachineState.flush: 'flush',
    MachineState.heating: 'heating',
    MachineState.cleaning: 'cleaning',
    MachineState.descaling: 'descaling',
  };

  static MachineState fromBridge(String name) {
    return _fromBridge[name] ?? MachineState.idle;
  }

  static MachineSubstate substateFromBridge(String name) {
    for (final s in MachineSubstate.values) {
      if (s.name == name) return s;
    }
    return MachineSubstate.idle;
  }

  static String toBridge(MachineState state) {
    return _toBridge[state] ?? state.name;
  }
}

/// De1Interface implementation that talks to DecentBridge over HTTP/WebSocket.
class BridgeDe1 implements De1Interface {
  final BridgeClient _client;
  final String _deviceId;
  final String _name;
  final _log = Logger('BridgeDe1');

  // Streams
  final BehaviorSubject<MachineSnapshot> _snapshotSubject =
      BehaviorSubject<MachineSnapshot>();
  final BehaviorSubject<De1ShotSettings> _shotSettingsSubject =
      BehaviorSubject<De1ShotSettings>();
  final BehaviorSubject<De1WaterLevels> _waterLevelsSubject =
      BehaviorSubject<De1WaterLevels>();
  final BehaviorSubject<ConnectionState> _connectionStateSubject =
      BehaviorSubject.seeded(ConnectionState.disconnected);
  final BehaviorSubject<bool> _readySubject = BehaviorSubject.seeded(false);

  // WebSocket subscriptions
  final List<StreamSubscription> _subscriptions = [];

  // Cached machine info
  MachineInfo _machineInfo = MachineInfo(
    version: '',
    model: '',
    serialNumber: '',
    groupHeadControllerPresent: false,
    extra: {},
  );

  // Local caches for settings not yet exposed by DecentBridge
  double _steamFlow = 1.0;
  double _hotWaterFlow = 1.0;
  double _flushFlow = 1.0;
  double _flushTimeout = 10.0;
  double _flushTemperature = 90.0;
  int _steamPurgeMode = 0;
  int _tankTempThreshold = 0;
  double _heaterPhase1Flow = 2.5;
  double _heaterPhase2Flow = 5.0;
  double _heaterPhase2Timeout = 5.0;
  double _heaterIdleTemp = 98.0;

  BridgeDe1({
    required BridgeClient client,
    required String deviceId,
    String name = 'DE1 (Bridge)',
  })  : _client = client,
        _deviceId = deviceId,
        _name = name;

  // ─── Device interface ───

  @override
  String get deviceId => _deviceId;

  @override
  String get name => _name;

  @override
  DeviceType get type => DeviceType.machine;

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateSubject.stream;

  @override
  Future<void> onConnect() async {
    _log.info('Connecting to DE1 via Bridge');
    _connectionStateSubject.add(ConnectionState.connecting);

    try {
      // 1. Fetch machine info
      final infoJson = await _client.get('/api/v1/machine/info');
      _machineInfo = MachineInfo.fromJson(infoJson);
      _log.fine('Machine info: ${_machineInfo.model} ${_machineInfo.version}');

      // 2. Fetch initial shot settings
      try {
        final settingsJson = await _client.get('/api/v1/machine/shotSettings');
        _shotSettingsSubject.add(De1ShotSettings.fromJson(settingsJson));
      } catch (e) {
        _log.warning('Failed to fetch initial shot settings: $e');
      }

      // 3. Fetch initial water levels
      try {
        final waterJson = await _client.get('/api/v1/machine/waterLevels');
        _waterLevelsSubject.add(De1WaterLevels.fromJson(waterJson));
      } catch (e) {
        _log.warning('Failed to fetch initial water levels: $e');
      }

      // 4. Fetch initial machine settings (fan, usb)
      try {
        final machineSettings =
            await _client.get('/api/v1/machine/settings');
        // Cache any available values
        _log.fine('Machine settings: $machineSettings');
      } catch (e) {
        _log.warning('Failed to fetch machine settings: $e');
      }

      // 5. Connect WebSocket channels
      _subscriptions.add(
        _client
            .connectWebSocket('/ws/v1/machine/snapshot')
            .listen(_onSnapshot),
      );
      _subscriptions.add(
        _client
            .connectWebSocket('/ws/v1/machine/shotSettings')
            .listen(_onShotSettings),
      );
      _subscriptions.add(
        _client
            .connectWebSocket('/ws/v1/machine/waterLevels')
            .listen(_onWaterLevels),
      );

      _connectionStateSubject.add(ConnectionState.connected);
      _readySubject.add(true);
      _log.info('Connected to DE1 via Bridge');
    } catch (e) {
      _log.severe('Failed to connect to DE1 via Bridge: $e');
      _connectionStateSubject.add(ConnectionState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _log.info('Disconnecting from DE1 via Bridge');
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _client.disconnectWebSocket('/ws/v1/machine/snapshot');
    _client.disconnectWebSocket('/ws/v1/machine/shotSettings');
    _client.disconnectWebSocket('/ws/v1/machine/waterLevels');
    _readySubject.add(false);
    _connectionStateSubject.add(ConnectionState.disconnected);
  }

  // ─── Machine interface ───

  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshotSubject.stream;

  @override
  MachineInfo get machineInfo => _machineInfo;

  @override
  Future<void> requestState(MachineState newState) async {
    final bridgeState = _StateMapping.toBridge(newState);
    _log.info('Requesting state: $bridgeState');
    await _client.put('/api/v1/machine/state/$bridgeState');
  }

  // ─── De1Interface ───

  @override
  Stream<bool> get ready => _readySubject.stream;

  @override
  Stream<De1RawMessage> get rawOutStream => const Stream.empty();

  @override
  void sendRawMessage(De1RawMessage message) {
    _log.warning('sendRawMessage not supported via Bridge');
  }

  @override
  Stream<De1ShotSettings> get shotSettings => _shotSettingsSubject.stream;

  @override
  Future<void> updateShotSettings(De1ShotSettings newSettings) async {
    await _client.post('/api/v1/machine/shotSettings', newSettings.toJson());
  }

  @override
  Stream<De1WaterLevels> get waterLevels => _waterLevelsSubject.stream;

  @override
  Future<void> setRefillLevel(int newRefillLevel) async {
    _log.fine('setRefillLevel: $newRefillLevel');
    // DecentBridge may not expose this yet
  }

  @override
  Future<void> setProfile(Profile profile) async {
    _log.info('Uploading profile: ${profile.title}');
    await _client.post('/api/v1/machine/profile', profile.toJson());
  }

  // ─── Fan / Tank thresholds ───

  @override
  Future<int> getFanThreshhold() async {
    final settings = await _client.get('/api/v1/machine/settings');
    return (settings['fan'] as num?)?.toInt() ?? 50;
  }

  @override
  Future<void> setFanThreshhold(int temp) async {
    await _client.post('/api/v1/machine/settings', {'fan': temp});
  }

  @override
  Future<int> getTankTempThreshold() async => _tankTempThreshold;

  @override
  Future<void> setTankTempThreshold(int temp) async {
    _tankTempThreshold = temp;
  }

  // ─── Flow Control (cached locally — not yet in DecentBridge API) ───

  @override
  Future<double> getSteamFlow() async => _steamFlow;

  @override
  Future<void> setSteamFlow(double newFlow) async {
    _steamFlow = newFlow;
    // Re-emit shot settings so De1Controller picks up the change
    if (_shotSettingsSubject.hasValue) {
      _shotSettingsSubject.add(_shotSettingsSubject.value);
    }
  }

  @override
  Future<double> getHotWaterFlow() async => _hotWaterFlow;

  @override
  Future<void> setHotWaterFlow(double newFlow) async {
    _hotWaterFlow = newFlow;
    if (_shotSettingsSubject.hasValue) {
      _shotSettingsSubject.add(_shotSettingsSubject.value);
    }
  }

  @override
  Future<double> getFlushFlow() async => _flushFlow;

  @override
  Future<void> setFlushFlow(double newFlow) async {
    _flushFlow = newFlow;
  }

  @override
  Future<double> getFlushTimeout() async => _flushTimeout;

  @override
  Future<void> setFlushTimeout(double newTimeout) async {
    _flushTimeout = newTimeout;
  }

  @override
  Future<double> getFlushTemperature() async => _flushTemperature;

  @override
  Future<void> setFlushTemperature(double newTemp) async {
    _flushTemperature = newTemp;
  }

  // ─── USB / Steam purge ───

  @override
  Future<bool> getUsbChargerMode() async {
    final settings = await _client.get('/api/v1/machine/settings');
    return settings['usb'] as bool? ?? false;
  }

  @override
  Future<void> setUsbChargerMode(bool t) async {
    await _client.post('/api/v1/machine/settings', {'usb': t});
  }

  @override
  Future<int> getSteamPurgeMode() async => _steamPurgeMode;

  @override
  Future<void> setSteamPurgeMode(int mode) async {
    _steamPurgeMode = mode;
  }

  // ─── Heater settings (cached locally) ───

  @override
  Future<double> getHeaterPhase1Flow() async => _heaterPhase1Flow;

  @override
  Future<void> setHeaterPhase1Flow(double val) async {
    _heaterPhase1Flow = val;
  }

  @override
  Future<double> getHeaterPhase2Flow() async => _heaterPhase2Flow;

  @override
  Future<void> setHeaterPhase2Flow(double val) async {
    _heaterPhase2Flow = val;
  }

  @override
  Future<double> getHeaterPhase2Timeout() async => _heaterPhase2Timeout;

  @override
  Future<void> setHeaterPhase2Timeout(double val) async {
    _heaterPhase2Timeout = val;
  }

  @override
  Future<double> getHeaterIdleTemp() async => _heaterIdleTemp;

  @override
  Future<void> setHeaterIdleTemp(double val) async {
    _heaterIdleTemp = val;
  }

  // ─── Firmware ───

  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) async {
    throw UnimplementedError('Firmware update via Bridge not yet supported');
  }

  // ─── WebSocket data handlers ───

  void _onSnapshot(Map<String, dynamic> json) {
    try {
      // Map state names from Bridge to ReaPrime
      if (json.containsKey('state') && json['state'] is Map) {
        final stateMap = json['state'] as Map<String, dynamic>;
        if (stateMap.containsKey('state')) {
          stateMap['state'] =
              _StateMapping.fromBridge(stateMap['state'] as String).name;
        }
        if (stateMap.containsKey('substate')) {
          stateMap['substate'] =
              _StateMapping.substateFromBridge(stateMap['substate'] as String)
                  .name;
        }
      }
      final snapshot = MachineSnapshot.fromJson(json);
      _snapshotSubject.add(snapshot);
    } catch (e) {
      _log.warning('Failed to parse machine snapshot: $e\nRaw JSON: $json');
    }
  }

  void _onShotSettings(Map<String, dynamic> json) {
    try {
      _shotSettingsSubject.add(De1ShotSettings.fromJson(json));
    } catch (e) {
      _log.warning('Failed to parse shot settings: $e');
    }
  }

  void _onWaterLevels(Map<String, dynamic> json) {
    try {
      _waterLevelsSubject.add(De1WaterLevels.fromJson(json));
    } catch (e) {
      _log.warning('Failed to parse water levels: $e');
    }
  }
}
