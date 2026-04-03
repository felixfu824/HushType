# VoxKey

Local voice-to-text input for macOS and iOS. Hold a key (macOS) or tap a button (iOS keyboard) — speak — transcribed text appears at your cursor. Handles mixed English/Chinese with Traditional Chinese output.

Uses [Qwen3-ASR](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit) running locally on Apple Silicon via MLX. No cloud API, no subscription, no data leaves your network.

## How It Works

```
macOS (standalone):
  Hold Right Option → speak → release → text at cursor
  Pipeline: mic → Qwen3-ASR (MLX, on-device) → OpenCC s2twp → paste

iOS (via Mac server):
  Open VoxKey app → Start Listening → switch to any app → VoxKey keyboard → tap mic
  Pipeline: iPhone mic → HTTP → Mac server → Qwen3-ASR → OpenCC s2twp → result → iPhone keyboard → insert text
```

```
                                     ┌──────────────────────────────────┐
                                     │  Mac (Apple Silicon)             │
  ┌──────────────┐   WiFi/Tailscale  │                                  │
  │ iPhone       │ ──── HTTP POST ──►│  ios_server.py (port 8000)       │
  │ VoxKey KB    │◄── JSON result ───│    ↓                             │
  └──────────────┘                   │  mlx-audio (port 8199)           │
                                     │    → Qwen3-ASR 0.6B (MLX/Metal) │
                                     │    → OpenCC s2twp                │
                                     │                                  │
                                     │  VoxKey.app (menu bar)           │
                                     │    → Right Option hotkey         │
                                     │    → Local transcription         │
                                     └──────────────────────────────────┘
```

## Prerequisites

| Requirement | Purpose |
|---|---|
| Mac with Apple Silicon (M1+) | MLX inference requires Metal GPU |
| macOS 15.0+ | Minimum OS for speech-swift |
| Python 3.13+ | iOS server (mlx-audio) |
| Xcode 16+ | Building both macOS and iOS apps |
| Homebrew | Installing opencc, xcodegen |
| iPhone (any model) | iOS client (optional) |
| Tailscale | Remote iPhone-to-Mac connectivity (optional, LAN also works) |

## Quick Start -- macOS Only

```bash
git clone https://github.com/felixfu824/VoxKey.git
cd VoxKey

# Install dependencies
brew install opencc

# Build and install to /Applications
make install
```

Launch VoxKey from Spotlight (Cmd+Space -> VoxKey).

**First launch:**
1. Grant **Accessibility** permission (System Settings > Privacy & Security > Accessibility)
2. Grant **Microphone** permission when prompted
3. Wait for model download (~675 MB, one-time)

**Usage:** Hold Right Option -> speak -> release -> text appears at cursor.

## Quick Start -- iOS (iPhone + Mac Server)

### Step 1: Install server dependencies on Mac

```bash
pip3 install "mlx-audio[stt,server]" webrtcvad-wheels setuptools httpx
brew install opencc xcodegen
```

### Step 2: Start the iOS server

**Option A (from VoxKey menu bar):** Click the VoxKey icon -> "Start iOS Server"

**Option B (from terminal):**
```bash
python3 scripts/ios_server.py
# Starts frontend on 0.0.0.0:8000, backend on 127.0.0.1:8199
# First request downloads the model (~675 MB)
```

### Step 3: Build and install the iOS app

```bash
cd iOS
xcodegen generate
open VoxKey.xcodeproj
```

In Xcode:
1. Select your Apple ID team in Signing & Capabilities (both VoxKey and VoxKeyKeyboard targets)
2. Connect iPhone via USB
3. Build & Run (Cmd+R)

### Step 4: iPhone setup

1. **Enable Developer Mode:** Settings > Privacy & Security > Developer Mode > On (requires restart)
2. **Trust developer:** Settings > General > VPN & Device Management > trust your Apple ID
3. **Add keyboard:** Settings > General > Keyboard > Keyboards > Add New Keyboard > VoxKey
4. **Enable Full Access:** Tap VoxKey in the keyboard list > Allow Full Access

### Step 5: Use it

1. Open VoxKey app on iPhone
2. Enter Mac's IP address (Tailscale: `tailscale ip -4` on Mac, or LAN IP)
3. Tap "Test Connection" to verify
4. Tap **"Start Listening"** (orange mic dot appears, 5-minute session)
5. Switch to any app (Messages, Notes, etc.)
6. Long-press globe key > switch to VoxKey keyboard
7. Tap mic > speak > tap stop > text appears

## Configuration

### macOS

```bash
# View all settings
defaults read com.felix.voxkey

# Language: nil=auto, "english", "chinese", "japanese"
defaults write com.felix.voxkey voxkey.language -string "chinese"

# Model: default 0.6B-4bit, alternative 1.7B for better quality
defaults write com.felix.voxkey voxkey.modelId -string "mlx-community/Qwen3-ASR-1.7B-8bit"

# Traditional Chinese conversion (default: true)
defaults write com.felix.voxkey voxkey.chineseConversionEnabled -bool false
```

### iOS

- Server URL: configured in the app UI (persisted in App Group)
- Session duration: 5 minutes (hardcoded in BackgroundAudioManager.swift)
- Model: `mlx-community/Qwen3-ASR-0.6B-4bit` (hardcoded in RemoteTranscriber.swift)

### Changing the Hotkey (macOS)

Edit `Sources/VoxKey/HotkeyManager.swift`:
```swift
private static let rightOptionKeyCode: Int64 = 61
```

Common keycodes: Right Option (61), Right Command (54), Left Option (58), Left Control (59), Fn/Globe (63).

## Project Structure

```
VoxKey/
├── Package.swift                      SPM config (macOS target)
├── Makefile                           build / install / clean
├── Sources/VoxKey/                    macOS menu bar app
│   ├── main.swift                     NSApplication bootstrap
│   ├── AppDelegate.swift              Orchestrator + state machine
│   ├── StatusBarController.swift      Menu bar icon + menus + iOS server toggle
│   ├── IOSServerManager.swift         Manages ios_server.py subprocess
│   ├── HotkeyManager.swift            CGEvent tap for Right Option
│   ├── AudioCaptureService.swift      AVAudioEngine mic capture (16kHz mono)
│   ├── TranscriptionEngine.swift      Protocol + Qwen3ASR wrapper (MLX)
│   ├── ChineseConverter.swift         OpenCC s2twp (Simplified → Traditional)
│   ├── TextInserter.swift             Clipboard + Cmd+V paste
│   ├── InputSourceManager.swift       CJK input method detection
│   └── AppConfig.swift                UserDefaults wrapper
├── scripts/
│   ├── ios_server.py                  FastAPI proxy: mlx-audio + OpenCC
│   └── build_mlx_metallib.sh          MLX Metal shader compilation
├── Resources/
│   └── Info.plist                     LSUIElement, mic usage description
└── iOS/                               iPhone app + keyboard extension
    ├── project.yml                    xcodegen project spec
    ├── Shared/                        Shared between app + keyboard extension
    │   ├── AppGroupConstants.swift    App Group keys + file-based IPC
    │   ├── IPCConstants.swift         Darwin notification names
    │   └── WAVEncoder.swift           Float32 → 16-bit PCM WAV
    ├── VoxKey/                        Main iOS app
    │   ├── VoxKeyApp.swift            SwiftUI entry point
    │   ├── Views/ContentView.swift    Server config, listening session, status
    │   ├── Services/
    │   │   ├── AudioRecorder.swift    AVAudioEngine with listening + recording modes
    │   │   ├── BackgroundAudioManager.swift  Session management, IPC polling, background
    │   │   └── RemoteTranscriber.swift       HTTP multipart POST to Mac server
    │   └── Resources/silence.wav      (unused, kept for fallback)
    └── VoxKeyKeyboard/                Custom keyboard extension
        └── KeyboardViewController.swift  Mic button, space, backspace, return, globe
```

## Customizing for Your Own Setup

To run VoxKey on your own devices, change these:

| What | Where | Example |
|---|---|---|
| Bundle ID | `iOS/project.yml` (both targets) + `iOS/Shared/AppGroupConstants.swift` | `com.yourname.voxkey` / `group.com.yourname.voxkey` |
| Server URL default | `iOS/VoxKey/Views/ContentView.swift` | Your Tailscale or LAN IP |
| Hotkey | `Sources/VoxKey/HotkeyManager.swift` | Any modifier keycode |
| Model | `iOS/VoxKey/Services/RemoteTranscriber.swift` + `scripts/ios_server.py` | `mlx-community/Qwen3-ASR-1.7B-8bit` for better quality |
| Session timeout | `iOS/VoxKey/Services/BackgroundAudioManager.swift` | `sessionDuration` property |
| OpenCC config | `Sources/VoxKey/ChineseConverter.swift` + `scripts/ios_server.py` | Change `s2twp` to `s2t` for standard Traditional |

## Troubleshooting

**macOS: "MLX error: Failed to load the default metallib"**
Run: `bash scripts/build_mlx_metallib.sh release`

**macOS: Hotkey not working**
Check Accessibility permission. VoxKey (or Terminal if running via `make run`) must be listed.

**iOS: "App Transport Security" error**
The Info.plist must have `NSAllowsArbitraryLoads = true` with NO `NSExceptionDomains` (they conflict and cause iOS to ignore the global allow).

**iOS: Keyboard stuck on "Transcribing..."**
The main app isn't receiving commands. Ensure:
1. VoxKey app is open and showing "Listening" with the orange mic dot
2. The Mac server is running (`curl http://<mac-ip>:8000/`)
3. App Group container works (check Xcode console for "App Group container: /path...")

**iOS: "Open VoxKey app first"**
The main app isn't running or the listening session expired (5-min timeout). Open VoxKey app and tap "Start Listening" again.

**iOS: App stops working after 7 days**
Free provisioning signing expires. Reconnect iPhone via USB, open Xcode, Cmd+R to reinstall. Settings are preserved. A paid Apple Developer account ($99/year) extends this to 1 year.

**Server: Port already in use**
```bash
lsof -ti :8000 :8199 | xargs kill
```

## Known Limitations

- iOS requires Mac to be on and server running (no cloud fallback)
- Free provisioning: iOS app expires every 7 days (re-sign via Xcode)
- Session timeout is fixed at 5 minutes (no UI to change it yet)
- No app icon yet (uses default)

## Dependencies

| Dependency | Purpose | Install |
|---|---|---|
| [speech-swift](https://github.com/soniqo/speech-swift) | Qwen3-ASR on Apple Silicon (MLX) | Automatic via SPM |
| [opencc](https://formulae.brew.sh/formula/opencc) | Simplified → Traditional Chinese | `brew install opencc` |
| [mlx-audio](https://github.com/Blaizzy/mlx-audio) | STT server for iOS | `pip3 install "mlx-audio[stt,server]"` |
| [xcodegen](https://github.com/yonaskolb/XcodeGen) | iOS Xcode project generation | `brew install xcodegen` |
| [httpx](https://www.python-httpx.org/) | Async HTTP for proxy server | `pip3 install httpx` |
