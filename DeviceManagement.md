# Device Management in Streamline

This document explains how devices (DE1 machines, scales) are discovered, connected, and managed.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Application Layer                     │
│        (UI, De1StateManager)                            │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│              Controller Layer                            │
│   De1Controller  │  ScaleController  │  SensorController│
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│              Device Controller                           │
│   Coordinates discovery services and device stream      │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│           Discovery Services Layer                       │
│  BridgeDiscoveryService  │  SimulatedDeviceService      │
└─────────────────┬───────────────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────────────┐
│          DecentBridge (HTTP/WebSocket)                    │
│   BridgeDe1  │  BridgeScale                             │
└─────────────────────────────────────────────────────────┘
```

**Key Principles:**
- **Client-only**: Streamline does not communicate with devices directly. All device interaction goes through DecentBridge over HTTP/WebSocket.
- **Constructor Dependency Injection**: All dependencies passed through constructors.
- **Reactive Streams**: RxDart BehaviorSubjects for state broadcasting.
- **Abstract Interfaces**: Controllers depend on `De1Interface` and `Scale` abstractions, not concrete implementations.

## Discovery

### BridgeDiscoveryService

**File:** `lib/src/services/bridge/bridge_discovery_service.dart`

Discovers DecentBridge on the local network using mDNS/Zeroconf (`bonsoir` package, service type `_decentbridge._tcp`).

**Discovery flow:**
1. Start mDNS discovery for `_decentbridge._tcp`
2. Read connection info from TXT record attributes (`ip`, `port`, `ws`)
3. Connect to DecentBridge at discovered address
4. Query `GET /api/v1/devices` to list connected devices
5. Create `BridgeDe1` and/or `BridgeScale` instances
6. Emit device list via stream

**Fallback:** If mDNS fails, users can manually configure the bridge host/port in Settings.

### SimulatedDeviceService

**File:** `lib/src/services/simulated_device_service.dart`

Creates mock devices for testing without hardware. Activated with `--dart-define simulate=1` or via Settings.

## Device Implementations

Located in `lib/src/models/device/impl/`:

### BridgeDe1

**File:** `lib/src/models/device/impl/bridge_de1/bridge_de1.dart`

Implements `De1Interface` by talking to DecentBridge over HTTP/WebSocket.

**Streams (WebSocket):**
- `currentSnapshot` via `/ws/v1/machine/snapshot`
- `shotSettings` via `/ws/v1/machine/shotSettings`
- `waterLevels` via `/ws/v1/machine/waterLevels`

**Commands (REST):**
- `requestState()` → `PUT /api/v1/machine/state/{state}`
- `setProfile()` → `POST /api/v1/machine/profile`
- `updateShotSettings()` → `POST /api/v1/machine/shotSettings`
- Machine settings (fan, USB, flow) → `GET/POST /api/v1/machine/settings`

### BridgeScale

**File:** `lib/src/models/device/impl/bridge_scale/bridge_scale.dart`

Implements `Scale` by talking to DecentBridge.

- `currentSnapshot` via WebSocket `/ws/v1/scale/snapshot`
- `tare()` → `PUT /api/v1/scale/tare`

### Mock Devices

- `lib/src/models/device/impl/mock_de1/` — Simulated DE1 for testing
- `lib/src/models/device/impl/mock_scale/` — Simulated scale for testing

## Connection Flow

### App Startup

```
1. main.dart creates BridgeDiscoveryService + SimulatedDeviceService
2. Creates DeviceController, De1Controller, ScaleController
3. runApp() → PermissionsView displayed
4. User grants permissions → deviceController.initialize()
5. BridgeDiscoveryService discovers DecentBridge via mDNS
6. Queries DecentBridge for connected devices
7. ScaleController auto-connects to first found scale
8. User selects DE1 from list → De1Controller.connectToDe1()
9. Navigate to HomeScreen
```

## Controllers

### De1Controller
**File:** `lib/src/controllers/de1_controller.dart`

Manages DE1 connection (manual, user-selected). Exposes machine state, shot settings, and flow control streams.

### ScaleController
**File:** `lib/src/controllers/scale_controller.dart`

Auto-connects to first discovered scale. Processes weight and flow data.

### De1StateManager
**File:** `lib/src/controllers/de1_state_manager.dart`

Orchestrates machine state changes, scale power management, and shot tracking.

## Adding Support for New Device Types

Since Streamline is a client of DecentBridge, adding new device types requires:

1. DecentBridge must support the new device (BLE communication)
2. DecentBridge must expose the device's API endpoints
3. Create a new Bridge implementation in `lib/src/models/device/impl/` that talks to those endpoints
4. Register the device type in `BridgeDiscoveryService`
5. Optionally create a controller if specialized logic is needed
