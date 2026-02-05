import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bridge_de1/bridge_de1.dart';
import 'package:reaprime/src/models/device/impl/bridge_scale/bridge_scale.dart';
import 'package:reaprime/src/services/bridge/bridge_client.dart';
import 'package:rxdart/rxdart.dart';

/// Service type that DecentBridge registers via mDNS/Zeroconf.
const String kBridgeServiceType = '_decentbridge._tcp';

/// Discovers DecentBridge instances on the local network using mDNS,
/// then queries each for connected devices and creates BridgeDe1/BridgeScale
/// instances.
class BridgeDiscoveryService implements DeviceDiscoveryService {
  final _log = Logger('BridgeDiscoveryService');

  /// If non-empty, skip mDNS and use this host directly.
  final String? manualHost;
  final int httpPort;
  final int wsPort;

  BridgeClient? _client;
  BonsoirDiscovery? _discovery;
  StreamSubscription? _discoverySubscription;

  final BehaviorSubject<List<Device>> _deviceSubject =
      BehaviorSubject.seeded([]);

  BridgeDiscoveryService({
    this.manualHost,
    this.httpPort = 8080,
    this.wsPort = 8081,
  });

  @override
  Stream<List<Device>> get devices => _deviceSubject.stream;

  /// The current BridgeClient, available after a bridge has been found.
  BridgeClient? get client => _client;

  @override
  Future<void> initialize() async {
    _log.info('Initializing BridgeDiscoveryService');
  }

  @override
  Future<void> scanForDevices() async {
    _log.info('Scanning for DecentBridge...');

    if (manualHost != null && manualHost!.isNotEmpty) {
      _log.info('Using manual host: $manualHost');
      await _connectToBridge(manualHost!, httpPort, wsPort);
      return;
    }

    // Use mDNS to discover DecentBridge on the local network
    await _discoverViaMdns();
  }

  Future<void> _discoverViaMdns() async {
    _discovery?.stop();
    _discoverySubscription?.cancel();

    _discovery = BonsoirDiscovery(type: kBridgeServiceType);
    await _discovery!.ready;

    final completer = Completer<void>();
    Timer? timeout;

    _discoverySubscription =
        _discovery!.eventStream?.listen((event) async {
      _log.fine('mDNS event: ${event.type}, service: ${event.service}');

      if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
        final service = event.service as ResolvedBonsoirService;
        final host = service.host ?? service.name;
        final port = service.port;
        _log.info('Resolved DecentBridge via mDNS: $host:$port');

        // WS port from attributes (key may be "ws" or "wsPort")
        final wsPortDiscovered =
            int.tryParse(service.attributes['ws'] ?? '') ??
            int.tryParse(service.attributes['wsPort'] ?? '') ??
            wsPort;

        timeout?.cancel();
        await _connectToBridge(host, port, wsPortDiscovered);
        if (!completer.isCompleted) completer.complete();
      } else if (event.type ==
          BonsoirDiscoveryEventType.discoveryServiceFound) {
        final service = event.service;
        _log.info(
          'Found DecentBridge service: ${service?.name} '
          '(port=${service?.port}, attrs=${service?.attributes})',
        );

        // On some platforms (Windows), SRV resolution may not work.
        // Fall back to TXT record attributes: ip, port, ws.
        final attrs = service?.attributes ?? {};
        final attrIp = attrs['ip'] ?? '';
        final attrPort = int.tryParse(attrs['port'] ?? '') ?? 0;
        final attrWs = int.tryParse(attrs['ws'] ?? '') ?? wsPort;

        if (attrIp.isNotEmpty && attrPort > 0) {
          _log.info(
            'Using TXT record attributes: ip=$attrIp, port=$attrPort, ws=$attrWs',
          );
          timeout?.cancel();
          await _connectToBridge(attrIp, attrPort, attrWs);
          if (!completer.isCompleted) completer.complete();
        }
      } else if (event.type ==
          BonsoirDiscoveryEventType.discoveryServiceResolveFailed) {
        _log.warning(
          'Failed to resolve DecentBridge service: ${event.service?.name}',
        );
      }
    });

    await _discovery!.start();

    // Timeout after 10 seconds if no bridge found
    timeout = Timer(const Duration(seconds: 10), () {
      if (!completer.isCompleted) {
        _log.warning('mDNS discovery timed out, no DecentBridge found');
        completer.complete();
      }
    });

    await completer.future;
  }

  Future<void> _connectToBridge(
    String host,
    int httpPort,
    int wsPort,
  ) async {
    _client = BridgeClient(
      httpBaseUrl: 'http://$host:$httpPort',
      wsBaseUrl: 'ws://$host:$wsPort',
    );

    final reachable = await _client!.isReachable();
    if (!reachable) {
      _log.warning('DecentBridge at $host:$httpPort is not reachable');
      _client = null;
      return;
    }

    _log.info('Connected to DecentBridge at $host:$httpPort');

    // Trigger a BLE scan on the bridge
    try {
      await _client!.get('/api/v1/devices/scan');
    } catch (e) {
      _log.fine('Scan request: $e');
    }

    // Wait a moment for scan results
    await Future.delayed(const Duration(seconds: 2));

    // Query connected devices
    await _refreshDevices();
  }

  Future<void> _refreshDevices() async {
    if (_client == null) return;

    try {
      final deviceList = await _client!.getList('/api/v1/devices');
      final List<Device> devices = [];

      for (final deviceJson in deviceList) {
        final map = deviceJson as Map<String, dynamic>;
        final type = map['type'] as String? ?? '';
        final id = map['id'] as String? ?? map['name'] as String? ?? '';
        final name = map['name'] as String? ?? type;

        if (type == 'machine') {
          devices.add(BridgeDe1(
            client: _client!,
            deviceId: id,
            name: name,
          ));
        } else if (type == 'scale') {
          devices.add(BridgeScale(
            client: _client!,
            deviceId: id,
            name: name,
          ));
        }
      }

      _log.info('Found ${devices.length} devices via DecentBridge');
      _deviceSubject.add(devices);
    } catch (e) {
      _log.warning('Failed to query devices from DecentBridge: $e');
    }
  }

  void dispose() {
    _discoverySubscription?.cancel();
    _discovery?.stop();
    _client?.dispose();
    _deviceSubject.close();
  }
}
