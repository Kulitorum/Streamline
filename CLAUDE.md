# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ReaPrime (R1) is a multi-platform Flutter client app for Decent Espresso machines. It connects to **DecentBridge** — a C++/Qt server running on the tablet that handles BLE communication with DE1 machines and scales. ReaPrime communicates with DecentBridge over HTTP (REST) and WebSocket to display machine state, upload profiles, control the machine, and track shots.

Primary target is Android tablets shipped with Decent machines, but also supports macOS, Linux (x86_64 + ARM64/Raspberry Pi), and Windows.

**Dart SDK:** ^3.7.0

## Build & Run Commands

Use the build wrapper script to inject git metadata (commit, branch, version):

```bash
./flutter_with_commit.sh run                          # Run the app
./flutter_with_commit.sh run --dart-define simulate=1  # Run with simulated devices (no hardware needed)
./flutter_with_commit.sh build apk --release           # Android APK
./flutter_with_commit.sh build macos --release         # macOS
./flutter_with_commit.sh build linux --release         # Linux
./flutter_with_commit.sh build windows --release       # Windows
./flutter_with_commit.sh test                          # Run all tests
```

Direct Flutter commands work but won't inject build info:

```bash
flutter pub get                     # Install dependencies
flutter test                        # Run all tests
flutter test test/profile_test.dart # Run a single test file
flutter analyze                     # Static analysis (uses flutter_lints)
dart format lib/                    # Format code
```

Docker-based Linux ARM64 builds (requires Colima): `make build-arm`

## Architecture

```
Device <-BLE-> DecentBridge (server) <-HTTP/WS-> ReaPrime (client)
```

ReaPrime is a **client-only** app. It does not do BLE or serial communication directly. All device interaction goes through DecentBridge's REST API (port 8080) and WebSocket API (port 8081).

### Layered structure (`lib/src/`):

```
UI (features/)  →  Controllers (controllers/)  →  Services (services/)  →  Models (models/)
```

- **Features** (`features/`): UI modules organized by feature (home, history, realtime_shot, settings, etc.). Each contains widgets/, forms/, tiles/ subdirectories.
- **Controllers** (`controllers/`): Business logic layer. Expose state via RxDart `BehaviorSubject` streams. All dependencies injected through constructors.
- **Services** (`services/`): Infrastructure — bridge discovery (mDNS via `bonsoir`), storage (Hive CE, file-based), Android foreground task, WebUI static file server (Shelf on port 3000).
- **Models** (`models/`): Domain entities split into `data/` (Profile, Workflow, ShotRecord) and `device/` (Device, Scale, De1Interface abstractions with concrete implementations in `impl/`).

### Key patterns

- **Reactive streams**: Controllers expose `Stream<T>` via `BehaviorSubject`. UI and services subscribe to these streams.
- **Constructor DI**: No service locators. All dependencies passed through constructors, wired up in `main.dart`.
- **Abstract device interfaces**: `Device`, `Scale`, `De1Interface` are abstract. Implementations live in `models/device/impl/` (bridge_de1, bridge_scale, mock variants).
- **Bridge communication**: `BridgeClient` (`services/bridge/bridge_client.dart`) provides shared HTTP + WebSocket infrastructure. `BridgeDe1` and `BridgeScale` implement device interfaces by talking to DecentBridge.
- **Bridge discovery**: `BridgeDiscoveryService` uses mDNS/Zeroconf (`bonsoir` package) to auto-discover DecentBridge on the local network (service type `_decentbridge._tcp`). Manual host override available in settings.
- **Plugin system** (`plugins/`): JavaScript plugins run in a sandboxed JS runtime (`flutter_js`). Plugins provide host APIs (log, emit, storage, fetch) and respond to events. Plugin `fetch()` calls to `localhost:8080` are automatically redirected to the DecentBridge URL.

### DecentBridge API

REST API on port 8080, WebSocket on port 8081:

- `GET/PUT /api/v1/machine/state/{state}` — Machine state control
- `GET/POST /api/v1/machine/shotSettings` — Shot settings
- `POST /api/v1/machine/profile` — Profile upload
- `GET /api/v1/machine/info` — Machine info
- `GET /api/v1/machine/waterLevels` — Water level
- `GET/POST /api/v1/machine/settings` — Machine settings (fan, USB)
- `GET /api/v1/devices` — List connected devices
- `GET /api/v1/devices/scan` — Trigger BLE scan
- `PUT /api/v1/scale/tare` — Tare scale
- `PUT /api/v1/scale/disconnect` — Disconnect scale
- `WS /ws/v1/machine/snapshot` — Realtime machine snapshots
- `WS /ws/v1/machine/shotSettings` — Shot settings updates
- `WS /ws/v1/machine/waterLevels` — Water level updates
- `WS /ws/v1/scale/snapshot` — Realtime scale snapshots

### Initialization flow (`main.dart`)

Logging setup → Firebase init → platform-specific config → bridge settings → BridgeDiscoveryService + SimulatedDeviceService → Hive storage → controllers → plugins → foreground service (Android) → `runApp()`

## Device Implementations

Located in `models/device/impl/`:
- `bridge_de1/` — DE1 machine via DecentBridge HTTP/WebSocket
- `bridge_scale/` — Scale via DecentBridge HTTP/WebSocket
- `mock_de1/`, `mock_scale/` — Simulated devices for testing

## Key Dependencies

- **UI**: `shadcn_ui`, `fl_chart`
- **State**: `rxdart` (BehaviorSubject streams)
- **Storage**: `hive_ce` / `hive_ce_flutter` (local NoSQL), `shared_preferences`
- **Networking**: `http` (REST client to DecentBridge), `web_socket_channel` (WebSocket client)
- **Discovery**: `bonsoir` (mDNS/Zeroconf for auto-discovering DecentBridge)
- **WebUI**: `shelf`, `shelf_plus`, `shelf_static`, `shelf_cors_headers` (static file server on port 3000)
- **Plugins**: `flutter_js` (JS runtime, custom fork from git)
- **Firebase**: crashlytics, analytics, performance monitoring

## Bridge Settings

Users can configure DecentBridge connection in settings:
- **Bridge Host**: Manual host override (empty = auto-discover via mDNS)
- **Bridge HTTP Port**: REST API port (default 8080)
- **Bridge WS Port**: WebSocket port (default 8081)

## Releases

Git tags (`vX.Y.Z`) trigger CI builds for all platforms via `.github/workflows/release.yml`. Version is extracted from the tag by `flutter_with_commit.sh`. Pre-release suffixes (`-beta.N`, `-alpha.N`, `-rc.N`) mark as pre-release.
