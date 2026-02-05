# Streamline

> Streamline is a multi-platform Flutter client for Decent Espresso machines. It connects to [DecentBridge](https://github.com/Kulitorum/DecentBridge) — a C++/Qt server that handles BLE communication with DE1 machines and scales — and provides a modern UI for controlling your machine, managing profiles, and tracking shots.

## Architecture

```
Device <-BLE-> DecentBridge (server) <-HTTP/WS-> Streamline (client)
```

Streamline is a **client-only** app. All device communication goes through DecentBridge's REST API and WebSocket API. Streamline auto-discovers DecentBridge on the local network via mDNS/Zeroconf.

## Supported Platforms

- **Android** (primary — ships on Decent tablets)
- **macOS**
- **Linux** (x86_64 + ARM64/Raspberry Pi)
- **Windows**

## Features

### Machine Control
- Query and set machine state (on/off, espresso, steam, hot water, flush)
- Configure machine settings (temperatures, flow rates, fan threshold, USB charger mode)
- Upload v2 JSON profiles to the machine
- Real-time shot data streaming (pressure, flow, temperature)

### Scale Support
- Real-time weight streaming
- Tare control
- Automatic connection via DecentBridge

### Profiles
- Built-in library of curated default profiles
- Import/export profile collections
- Content-based deduplication (identical profiles share the same ID)
- Profile versioning with parent-child lineage tracking

### Plugins
Streamline features a JavaScript plugin system for extending functionality. [Read more](Plugins.md).

### WebUI
Streamline can serve a web-based UI skin (e.g., the Streamline Project skin) on `localhost:3000`, viewable in any browser on the same device.

## Building

### Prerequisites
- Flutter SDK (Dart ^3.7.0)
- Platform-specific toolchains (Android SDK, Xcode, Visual Studio, etc.)

### Build & Run

Use the build wrapper script to inject git metadata:

```bash
./flutter_with_commit.sh run                           # Run the app
./flutter_with_commit.sh run --dart-define simulate=1  # Run with simulated devices
./flutter_with_commit.sh build apk --release           # Android APK
./flutter_with_commit.sh build macos --release         # macOS
./flutter_with_commit.sh build linux --release         # Linux
./flutter_with_commit.sh build windows --release       # Windows
```

Or use Flutter directly (without build info injection):

```bash
flutter pub get          # Install dependencies
flutter test             # Run all tests
flutter analyze          # Static analysis
flutter run -d windows   # Run on Windows
```

On Windows, you can also use `run.bat` for quick launching.

### Docker-based Linux ARM64 builds

Requires Colima: `make build-arm`

## Configuration

### Bridge Connection

Streamline auto-discovers DecentBridge via mDNS. If auto-discovery doesn't work, you can manually configure in Settings:

- **Bridge Host**: IP address of the DecentBridge server
- **Bridge HTTP Port**: REST API port (default: 8080)
- **Bridge WS Port**: WebSocket port (default: 8081)

## Credits

Streamline is built on top of [ReaPrime](https://github.com/tadelv/reaprime) by [@tadelv](https://github.com/tadelv).

REA stands for "Reasonable Espresso App". Credit for the name goes to [@randomcoffeesnob](https://github.com/randomcoffeesnob). Thanks to [@mimoja](https://github.com/mimoja) for the first Flutter app version.
