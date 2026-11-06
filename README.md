# L23D

An iPhone app that scans objects and people into textured 3D models you can use in games and 3D editors (Blender, Unity, Godot, Unreal).

**Status:** v0.5.0. All three scan modes are built: objects, people with a helper, and people solo on a spin chair. On-phone model building and export for games are built too. Polish (v1.0) is next. See "What works now" below.

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

- **Object scanning** with Apple's guided capture: point at the object, fit the box, walk around it. After each lap you can flip the object, scan from another height, or finish.
- **Person scanning (helper mode):** the person stands still; a helper aims at their chest, taps Start, and walks around them. Photos are taken automatically when the phone reaches a new spot and is steady and sharp. A 3-ring map shows what's covered (inner = low, middle = chest height, outer = high). Each photo gets a person cutout (Apple Vision + LiDAR depth) so the room is ignored.
- **Person scanning (spin chair, solo):** put the phone on a tripod at chest height, 1–1.5 m from a swivel chair. Tap Start, sit down during the 5-second countdown, and turn slowly when the voice says so (20, 30 or 45 s per turn). A photo with LiDAR depth is taken every 0.4 s. Optional second spin with the phone raised to catch the top of the head.
- **On-phone model building** with a progress bar, time left, cancel, and retry. If the app closes mid-build, tap **Build Model** to pick up where it left off.
- **Scan library** with thumbnails, live build progress, rename, rebuild, and delete
- **3D viewer:** drag to spin, pinch to zoom. Shows real size (cm), triangle count, photo count, and storage used.
- **View in AR** (AR Quick Look) and **Share USDZ**
- **Export for games & 3D apps:** GLB, OBJ (.zip), or USDZ, with these options:
  - **Origin point:** bottom center (sits on the ground), center, or as scanned
  - **Units** (OBJ only): meters or centimeters
  - **Max texture size:** original, 4096, 2048, 1024 or 512 px
  - Share the file with AirDrop, Files, or any app
- **Device check:** tells you if this phone can scan
- **Debug builds only:** ••• menu → **Add Sample Model** makes a test box, so you can try the viewer in the Simulator

### Using exports

| App | Best format | How |
|---|---|---|
| Blender | GLB | File → Import → glTF 2.0 |
| Unity | GLB | Add the free *glTFast* package, then drag the .glb into Assets |
| Godot | GLB | Drag the .glb into the FileSystem panel |
| Unreal | GLB | Drag the .glb into the Content Browser (glTF importer) |
| Anything else | OBJ | Unzip, then import `model.obj` (textures are in `textures/`) |

Models are in meters with Y pointing up. GLB files pass the Khronos glTF validator.

### Tips for good person scans

- The person should stand very still, arms slightly away from the body, eyes on one spot.
- Plain, tight-ish clothes scan better than shiny or very loose ones. Hair is hard.
- Even light, no strong shadows. Walk slowly — the app skips blurry photos.
- Go all the way around 3 times: chest height, low (crouch), and high (phone above head).
- Spin chair: turn your feet, not your upper body. Keep your head facing the same way as your chest. Turn up the volume so you hear the cues.

### Tips for good object scans

- Use even, bright light. Avoid harsh shadows.
- Put the object on a plain surface with space all around it.
- Walk slowly. Do 3 laps (low, middle, high), or flip the object to capture its bottom.
- Shiny, see-through, or very thin objects scan poorly.

## Planned

| Version | Feature |
|---|---|
| ~~0.2.0~~ | ~~Object scanning, on-phone model building, 3D viewer, AR view~~ (done) |
| ~~0.3.0~~ | ~~Export for games/3D apps: GLB, OBJ, USDZ, with pivot, units and texture size options~~ (done) |
| ~~0.4.0~~ | ~~Person scan: a helper walks around a still person~~ (done) |
| ~~0.5.0~~ | ~~Person scan: spin chair + tripod (solo)~~ (done) |
| 1.0.0 | Polish: background processing, low-poly export, tips |
| later | HQ mode: build higher-detail models on a Mac |

## How it works

- **Capture:** Apple's Object Capture (RealityKit) guides you around an object and saves photos with LiDAR depth.
- **Build:** Apple's `PhotogrammetrySession` turns the photos into a textured model, right on the phone. On iPhone, Apple limits this to its "reduced" detail level. That is good for games. A later HQ mode will use a Mac for more detail.
- **Storage:** scans stay on the phone in the app's own folder. They are not backed up to iCloud because they are large.

## Project layout

```
Config/Version.xcconfig     app version + build number (bump on every change)
L23D/App                    app entry and root view
L23D/Models                 Scan record, scan modes and status
L23D/Storage                where scan files live on disk
L23D/Library                library grid, scan detail, new-scan picker, about
L23D/Capture/Object         guided object capture (Apple Object Capture)
L23D/Capture/Person         person capture: helper (ARKit) and spin-chair (LiDAR camera + voice) engines, coverage ring, blur check, person masks, frame store
L23D/Reconstruction         on-phone model building, model stats, thumbnails
L23D/Viewer                 3D model viewer
L23D/Export                 mesh format, USDZ reader/writer, GLB + OBJ writers, export screen, zip
L23D/Support                device checks, debug sample model
L23DTests                   unit tests (Swift Testing)
```

Each scan is stored in `Application Support/Scans/<id>/` with `Images/` (photos), `Checkpoint/`, `Model/model.usdz`, `thumbnail.jpg`, and `Exports/`. Person scans also have `Masks/`, `Depth/`, and `frames.json` (camera pose per photo).

The Xcode project uses synchronized folders: new files in `L23D/` or `L23DTests/` are picked up automatically.
