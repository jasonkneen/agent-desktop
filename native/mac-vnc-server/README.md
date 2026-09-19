# mac-vnc-server

`mac-vnc-server` is a macOS-only VNC/RFB server written in Swift. It captures the local Mac screen, accepts keyboard and mouse input from a VNC client, and exposes the session on a configurable TCP port.

The default setup is optimized for local testing with Apple Screen Sharing:

- bind address: `127.0.0.1`
- base port: `5900`
- password: generated and stored in `~/.mac-vnc-server/config.json`
- FPS target: adaptive `60 -> 45 -> 30`
- scale: `1.0`
- encoding: `auto`

Use SSH tunneling or an explicit LAN bind for remote use.

## Requirements

- macOS 13 or newer
- Xcode / Swift toolchain compatible with `swift-tools-version: 6.3`
- Screen Recording permission
- Accessibility / Post Event permission for keyboard and mouse injection

The package links macOS-native frameworks:

- `ScreenCaptureKit` for screen capture
- `CoreGraphics` / `ApplicationServices` for input injection and permissions
- `AppKit` for clipboard integration
- `zlib` for compressed framebuffer encodings

## Build

```sh
swift build -c release
```

The binary is produced at:

```text
.build/release/mac-vnc-server-dev
```

For an explicit Apple Silicon build:

```sh
swift build -c release --arch arm64
```

Local SwiftPM builds use the `mac-vnc-server-dev` name. The release workflow stages the same product as `mac-vnc-server` after signing it.

## Versioning

Development builds always report:

```text
0.0.0-development
```

The release workflow replaces that value with the Git tag being released, stripping a leading `v`. For example, release tag `v1.2.3` builds a binary that reports `1.2.3`.

Show the version:

```sh
./.build/release/mac-vnc-server-dev version
./.build/release/mac-vnc-server-dev --help
```

Startup, connection, and recovery information is always shown. Periodic framebuffer-update logs are shown only when the server is started with `--verbose`. Warnings and errors are always written to stderr.

Update an installed release binary from the latest GitHub release:

```sh
mac-vnc-server update
```

The command downloads the exact release assets, verifies the binary's SHA-256 checksum, and atomically replaces the installed release executable. Development binaries refuse self-update; install or invoke the signed `mac-vnc-server` release binary instead.

## Permissions

Run this once:

```sh
./.build/release/mac-vnc-server-dev permissions
```

Then grant the requested permissions in macOS System Settings:

- Privacy & Security -> Screen Recording
- Privacy & Security -> Accessibility

Restart the server after granting permissions.

Check current status:

```sh
./.build/release/mac-vnc-server-dev diagnose
```

If ScreenCaptureKit reports no displays after the Mac turns the screen off, wake the display and start the server again:

```sh
./.build/release/mac-vnc-server-dev wakeup
```

## Run locally

Default command:

```sh
./.build/release/mac-vnc-server-dev
```

Equivalent explicit command:

```sh
./.build/release/mac-vnc-server-dev run --bind 127.0.0.1 --port 5900 --fps auto --scale 1 --encoding auto
```

Register the server as a per-user macOS service and start it immediately:

```sh
./.build/release/mac-vnc-server-dev --service
```

This creates `~/Library/LaunchAgents/com.pablozaiden.mac-vnc-server.plist` and runs the
server in the logged-in user's Aqua UI session. The service starts again automatically
when that user logs in and is restarted by `launchd` if the process exits. The service
is classified as an interactive job so `launchd` does not apply background CPU and I/O
throttling to the frame-streaming workload. It uses the same server options, so options
can be combined with `--service`, for example:

```sh
mac-vnc-server --service --bind 0.0.0.0 --port 5900 --password '<your-password>'
```

Restart the registered service after replacing the binary:

```sh
mac-vnc-server --service-restart
```

Service output is written to:

```text
~/Library/Logs/mac-vnc-server/stdout.log
~/Library/Logs/mac-vnc-server/stderr.log
```

To remove the service:

```sh
launchctl bootout "gui/$(id -u)/com.pablozaiden.mac-vnc-server"
rm ~/Library/LaunchAgents/com.pablozaiden.mac-vnc-server.plist
```

By default, the server exposes both the combined desktop and each display individually:

```text
5900  all displays, composed as one virtual framebuffer
5901  display 1
5902  display 2
...   one additional port per display
```

Connect with Apple Screen Sharing:

```sh
open 'vnc://127.0.0.1:5900'
```

Password printed at startup:

```text
VNC password: XXXXXXXX
```

For unattended local testing, fill the native Screen Sharing password dialog with AppleScript:

```sh
open 'vnc://127.0.0.1:5900'
sleep 2
osascript -e 'tell application "System Events" to keystroke "XXXXXXXX"' \
          -e 'tell application "System Events" to key code 36'
```

Do not store test credentials in Keychain unless you explicitly want that behavior.

## Run on LAN

Bind all interfaces:

```sh
./.build/release/mac-vnc-server-dev --bind 0.0.0.0 --port 5900 --password '<your-password>'
```

Or bind a specific LAN IP:

```sh
./.build/release/mac-vnc-server-dev --bind 192.168.1.10 --port 5900 --password '<your-password>'
```

The server refuses unauthenticated non-loopback binds by default. To disable auth for clients that support unauthenticated VNC, you must opt in explicitly:

```sh
./.build/release/mac-vnc-server-dev --bind 0.0.0.0 --no-password --insecure-allow-no-auth
```

Classic VNC password auth is weak and limited by the protocol. For untrusted networks, prefer an SSH tunnel:

```sh
ssh -L 5900:127.0.0.1:5900 user@mac-host
open 'vnc://127.0.0.1:5900'
```

## CLI

```text
mac-vnc-server [run] [options]
mac-vnc-server permissions
mac-vnc-server diagnose
mac-vnc-server wakeup
mac-vnc-server update
mac-vnc-server version
mac-vnc-server --help
```

`run` is optional when the first argument is a flag.
`wakeup` sends a short user-activity assertion with `caffeinate` to wake the display when ScreenCaptureKit cannot see any displays.

Options:

| Option | Default | Description |
| --- | --- | --- |
| `--bind <ipv4>` | `127.0.0.1` | IPv4 address to listen on. |
| `--port <port>` / `-p <port>` | `5900` | TCP port, or base port when `--display` is omitted. |
| `--password <value>` | config file | Override the generated/configured classic VNC auth password for this run. |
| `--no-password` | off | Use unauthenticated VNC. Apple Screen Sharing does not accept this path. |
| `--insecure-allow-no-auth` | off | Required with `--no-password` on non-loopback binds. |
| `--fps <auto\|1...120>` | `auto` | Adaptive `60 -> 45 -> 30` target, or a fixed framebuffer update rate when an explicit number is provided. |
| `--scale <value>` | `1.0` | Base virtual framebuffer scale. Adaptive sessions may temporarily use `0.75` or `0.67` for compatible generic clients that advertise DesktopSize when encoding or network pressure persists. Apple Screen Sharing remains at the negotiated framebuffer size until its resize dialect is implemented. |
| `--encoding <auto\|zrle\|zlib\|raw>` | `auto` | Framebuffer encoding preference. |
| `--display <all\|number>` | automatic | Display mode. Omit it to serve all displays on the base port and each display on consecutive ports. Use `all` for only the combined desktop, or a 1-based display number for only that display. |
| `--service` | off | Install and start a per-user macOS LaunchAgent in the logged-in Aqua UI session. |
| `--service-restart` | — | Restart the registered per-user macOS LaunchAgent. |
| `--verbose` | off | Enable periodic framebuffer-update logs on stdout. |
| `--clipboard-sync` | off | Enable basic text clipboard synchronization with the VNC client. |
| `--no-adaptive` | off | Disable adaptive FPS, compression, and automatic scale changes. |

### Password configuration

On the first authenticated run, the server generates an 8-character ASCII password and stores it in:

```text
~/.mac-vnc-server/config.json
```

The directory is created with permissions `0700` and the file with `0600`. The password is printed to stdout at startup. Subsequent runs reuse the same value. Use `--password <value>` for a one-off override, or `--no-password` for an explicitly unauthenticated server.

### Display modes

Omitting `--display` starts multiple listeners. With the default base port, `5900` keeps the previous combined-desktop behavior and `5901`, `5902`, ... expose each monitor separately:

```sh
./.build/release/mac-vnc-server-dev
open 'vnc://127.0.0.1:5900'  # all displays
open 'vnc://127.0.0.1:5901'  # display 1
open 'vnc://127.0.0.1:5902'  # display 2
```

To keep a single listener with the combined desktop:

```sh
./.build/release/mac-vnc-server-dev --display all
```

To serve only one monitor on the selected port:

```sh
./.build/release/mac-vnc-server-dev --display 1 --port 5900
```

Use `diagnose` to list display numbers:

```sh
./.build/release/mac-vnc-server-dev diagnose
```

## How it works

### RFB/VNC protocol

The server implements the RFB handshake and core client messages:

- protocol negotiation
- `SecurityType None` and classic VNC auth
- `SetPixelFormat`
- `SetEncodings`
- `FramebufferUpdateRequest`
- `KeyEvent`
- `PointerEvent`
- `ClientCutText`

Apple Screen Sharing negotiates RFB 3.3 and requires VNC auth, so authentication is enabled by default.

### Capture pipeline

Screen capture uses `ScreenCaptureKit` with one stream per selected display. Captured frames are stored in BGRA format and composed into a virtual framebuffer. The virtual framebuffer supports multiple displays and maps VNC coordinates back to macOS global coordinates for mouse input.

If macOS sleeps the screens while the server is running, the capture streams are rebuilt after `screensDidWakeNotification`, when an active `SCStream` reports `didStopWithError`, or when input arrives after a failed recovery. Recovery refreshes the shareable content and retries up to three times without closing the existing VNC session, so input handling remains connected.

When a client or network cannot consume updates quickly enough, the server keeps only the newest captured frame and drops stale frames before sending their RFB update header. Persistent Zlib/ZRLE state is transactional, so a dropped frame cannot desynchronize the stream. Client sockets use non-blocking writes with a five-second no-progress timeout; a connection that makes no write progress is closed instead of blocking the capture pipeline indefinitely. Adaptive sessions lower the output target from 60 to 45 to 30 FPS under sustained pressure and recover after sustained headroom; shared capture streams use the highest rate requested by their active clients.

Clients that advertise the standard `DesktopSize` pseudo-encoding can also enter a per-client scale ladder of `1.0 -> 0.75 -> 0.67` after sustained encoding or network pressure. Frames are resampled with Apple's Accelerate framework using high-quality filtering so the server reduces work and bandwidth only when needed. The session recovers one scale step after five healthy seconds. Clients without standard resize support remain at the configured scale and use FPS/backpressure adaptation instead.

### Encodings

`--encoding auto` chooses a compatible encoding based on the client:

- Apple Screen Sharing: persistent Zlib encoding (`6`)
- generic clients with ZRLE: ZRLE (`16`)
- generic clients with Zlib: Zlib (`6`)
- fallback: Raw (`0`)

Zlib is kept as a persistent stream per VNC connection, which is required for stable compressed updates with Apple Screen Sharing.
Adaptive compression prioritizes sender throughput: it uses level 1 when encoding is the bottleneck and at most level 3 when the network is the bottleneck. It does not automatically switch to high compression levels during video or animation.
ZRLE uses lossless solid-color, palette, packed-palette, and run-length tile modes, selecting the smallest representation for each changed tile. Dirty regions use smaller tiles when appropriate, and framebuffer update rectangles are batched into fewer socket writes.
The cursor is excluded from captured frames so the VNC client can render a single local cursor. This avoids showing both the captured macOS cursor and the client's pointer at the same time; the server does not synthesize a separate RichCursor shape because ScreenCaptureKit does not expose that shape through a stable public API.

### Input

Keyboard and mouse events are injected with `CGEvent`.

The server processes input on the read loop and streams framebuffer updates on a separate writer queue. This prevents keyboard/mouse events from getting stuck behind frame compression or socket writes.

For Apple Screen Sharing, `Alt_L` / `Alt_R` keysyms are remapped to macOS Command because the native client sends Command that way. This enables shortcuts such as `Cmd+C`, `Cmd+V`, `Cmd+W`, and `Cmd+Q`.

### Clipboard

Clipboard synchronization is disabled by default because the native macOS Screen Sharing client can apply incoming clipboard updates to the client's local pasteboard. Enable basic text synchronization explicitly when it is needed:

```sh
./.build/release/mac-vnc-server-dev run --clipboard-sync
```

This uses `NSPasteboard` and classic VNC cut text messages; full extended clipboard support is not implemented yet.

## GitHub Actions

This repository includes two workflows:

### CI

`.github/workflows/ci.yml`

Runs on pull requests and pushes to `main`:

- `swift test`
- `swift build -c release`

### Release

`.github/workflows/release.yml`

Runs when a GitHub Release is published:

- replaces `0.0.0-development` in `AppVersion.swift` with the release tag
- runs tests
- builds the `mac-vnc-server-dev` product for arm64
- stages it as `mac-vnc-server` and signs it with the persistent self-signed macOS certificate
- prepares the binary plus SHA-256 checksum
- uploads `mac-vnc-server` and `mac-vnc-server.sha256` to the GitHub Release

The workflow requires these repository secrets:

- `MAC_VNC_SERVER_MACOS_SIGNING_CERT_BASE64`
- `MAC_VNC_SERVER_MACOS_SIGNING_CERT_PASSWORD`

Generate the persistent certificate locally with:

```sh
./scripts/generate-macos-signing-cert.sh
```

Then load the certificate and password into GitHub without printing either secret:

```sh
base64 < .mac-vnc-server-signing/macos-signing.p12 | tr -d '\n' | \
  gh secret set MAC_VNC_SERVER_MACOS_SIGNING_CERT_BASE64 --repo PabloZaiden/mac-vnc-server
gh secret set MAC_VNC_SERVER_MACOS_SIGNING_CERT_PASSWORD \
  --repo PabloZaiden/mac-vnc-server < .mac-vnc-server-signing/macos-signing-password
```

The self-signed certificate provides a stable signing identity for macOS permissions; it does not provide notarization or Gatekeeper trust.

## Troubleshooting

### Apple Screen Sharing keeps asking for a password

The generated password is printed on server startup:

```text
VNC password: XXXXXXXX
```

For scripted testing, use AppleScript to type it instead of Keychain.

### Screen updates work, but input lags

Make sure you are running a build with the split reader/writer architecture. Rebuild:

```sh
swift build -c release
```

Then restart the server.

### Input works, but screen does not update

Use the default encoding first:

```sh
./.build/release/mac-vnc-server-dev --encoding auto
```

If the display slept while the server was running, wait briefly for the automatic ScreenCaptureKit recovery. If the display is still unavailable, the next keyboard or mouse event sends a `caffeinate` wake signal and triggers another asynchronous recovery attempt. The server logs `ScreenCaptureKit: capture recovered` when the streams are available again. If the server was started while the display was already asleep, run `mac-vnc-server wakeup` and start it again.

If testing a generic client, try:

```sh
./.build/release/mac-vnc-server-dev --encoding zrle
./.build/release/mac-vnc-server-dev --encoding zlib
./.build/release/mac-vnc-server-dev --encoding raw
```

### Port already in use

Use another port:

```sh
./.build/release/mac-vnc-server-dev --port 5903
open 'vnc://127.0.0.1:5903'
```

### Permissions are missing

Run:

```sh
./.build/release/mac-vnc-server-dev permissions
./.build/release/mac-vnc-server-dev diagnose
```

Then restart the server after granting permissions.
