# OpenShare

OpenShare V1 is a local-only Flutter file transfer app for Android and iOS.

## V1 Scope

- Same Wi-Fi phone-to-phone transfer only.
- Sender picks files, starts a local HTTP server, and advertises with mDNS.
- Receiver discovers senders with mDNS, or scans a QR fallback containing IP, port, and session token.
- Receiver downloads files with HTTP range resume support.
- Each file is verified with SHA256 from the sender manifest.
- Failed hash verification automatically retries the file.

Out of scope for V1: accounts, login, friends, chat, social features, backend, database, internet relay, ads, and AI features.

## Required Packages

The implementation uses `nsd`, `shelf`, `dio`, `mobile_scanner`, `qr_flutter`, `crypto`, and `file_picker`. `path_provider` is also used to write received files into the app documents directory.

## Platform Notes

iOS requires local network permission and Bonjour services in `ios/Runner/Info.plist`:

- `NSLocalNetworkUsageDescription`
- `NSBonjourServices` with `_http._tcp.`

Android uses cleartext HTTP only for local LAN connections and declares Wi-Fi/network permissions in `android/app/src/main/AndroidManifest.xml`.

## Run

Install Flutter, then run:

```sh
flutter pub get
flutter run
```

This workspace was scaffolded without a local Flutter executable available, so run formatting and device verification after installing Flutter:

```sh
dart format .
flutter analyze
flutter test
```
