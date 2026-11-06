# L23D

An iPhone app that scans objects and people into textured 3D models you can use in games and 3D editors (Blender, Unity, Godot, Unreal).

**Status:** early build (v0.1.0). The app shell and scan library are in place; capture comes next. See "What works now" below.

## What you need

- A Mac with **Xcode 27.2** or newer
- An **iPhone with LiDAR** (iPhone 12 Pro or newer *Pro* model) on **iOS 26** or newer
- A free or paid Apple developer account (to install on your phone)

The Simulator can run the library, viewer and export screens, but **it cannot scan**. Scanning needs the real camera and LiDAR.

## Run it on your iPhone

1. Open `L23D.xcodeproj` in Xcode.
2. Click the **L23D** project → **L23D** target → **Signing & Capabilities**.
3. Pick your **Team**. If Xcode says the bundle ID is taken, change `com.marcshawco.L23D` to something unique.
4. Plug in your iPhone, pick it at the top of Xcode, and press **Run** (⌘R).
5. On the phone, you may need to trust the developer: **Settings → General → VPN & Device Management**.

## Build and test from the command line

```bash
xcodebuild test -project L23D.xcodeproj -scheme L23D -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

```bash
xcodebuild build -project L23D.xcodeproj -scheme L23D -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

## What works now

- Scan library (empty state, grid, delete)
- "New Scan" picker with the three scan modes (Object, Person — Helper, Person — Spin Chair)
- Device check: tells you if this phone can scan
- About screen with the app version

## Planned

| Version | Feature |
|---|---|
| 0.2.0 | Object scanning with Apple's guided capture, on-phone model building, 3D viewer, AR view |
| 0.3.0 | Export for games/3D apps: GLB, OBJ, USDZ, with pivot, units and texture size options |
| 0.4.0 | Person scan: a helper walks around a still person |
| 0.5.0 | Person scan: spin chair + tripod (solo) |
| 1.0.0 | Polish: background processing, low-poly export, tips |
| later | HQ mode: build higher-detail models on a Mac |

## How it works

- **Capture:** Apple's Object Capture (RealityKit) guides you around an object and saves photos with LiDAR depth.
- **Build:** Apple's `PhotogrammetrySession` turns the photos into a textured model, right on the phone. On iPhone, Apple limits this to its "reduced" detail level. That is good for games. A later HQ mode will use a Mac for more detail.
- **Storage:** scans stay on the phone in the app's own folder. They are not backed up to iCloud because they are large.

## Project layout

```
Config/Version.xcconfig   app version + build number (bump on every change)
L23D/App                  app entry and root view
L23D/Models               Scan record, scan modes and status
L23D/Storage              where scan files live on disk
L23D/Library              library grid, new-scan picker, about
L23D/Support              device checks
L23DTests                 unit tests (Swift Testing)
```

The Xcode project uses synchronized folders: new files in `L23D/` or `L23DTests/` are picked up automatically.
