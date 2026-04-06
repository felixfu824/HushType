# CLAUDE.md — HushType

Local voice-to-text for macOS + iOS. Qwen3-ASR on Apple Silicon via MLX. MIT license.

## Build & Run

```bash
make install                    # Build macOS app → /Applications/HushType.app
make dmg                        # Build self-contained DMG (bundles OpenCC)
cd iOS && xcodegen generate     # Generate Xcode project for iOS
python3 scripts/ios_server.py   # Start iOS server manually (or use menu bar toggle)
```

Build outside OneDrive if `.build/` permissions fail: `swift build -c release --disable-sandbox --build-path /tmp/hushtype-build`

## Key Paths

| What | Path |
|---|---|
| macOS app source | `Sources/VoxKey/` (11 Swift files — dir name is legacy, not yet renamed) |
| iOS app + keyboard | `iOS/VoxKey/` (main app), `iOS/VoxKeyKeyboard/` (keyboard extension) |
| Shared IPC layer | `iOS/Shared/` (AppGroupConstants, IPCConstants, WAVEncoder) |
| iOS server | `scripts/ios_server.py` (FastAPI proxy: mlx-audio + OpenCC) |
| macOS entry point | `Sources/VoxKey/AppDelegate.swift` |
| Menu bar UI | `Sources/VoxKey/StatusBarController.swift` |
| Hotkey handler | `Sources/VoxKey/HotkeyManager.swift` (Right Option, keycode 61) |
| Chinese converter | `Sources/VoxKey/ChineseConverter.swift` (bundled OpenCC → fallback Homebrew) |
| iOS server manager | `Sources/VoxKey/IOSServerManager.swift` (Python path resolution, error alerts) |
| iOS main UI | `iOS/VoxKey/Views/ContentView.swift` |
| iOS keyboard | `iOS/VoxKeyKeyboard/KeyboardViewController.swift` |
| SPM config | `Package.swift` |
| iOS project spec | `iOS/project.yml` (xcodegen) |
| App icon | `Resources/HushType.png` (1024x1024), `Resources/HushType.icns` |
| Social preview | `Resources/HushType-social-preview.png` (1280x640) |
| Info.plist | `Resources/Info.plist` (version, bundle ID, LSUIElement) |
| Docs | `README.md`, `README.zh-TW.md`, `AGENT_SETUP.md` |

## Architecture (non-obvious decisions)

| Decision | Why | Reference |
|---|---|---|
| iPhone → Mac server, not on-device | iOS blocks Metal GPU in background; no CoreML port of Qwen3-ASR | `scripts/ios_server.py` |
| File-based IPC, not UserDefaults | UserDefaults cross-process broken with free provisioning | `iOS/Shared/AppGroupConstants.swift` |
| DispatchSourceTimer, not Timer | Timer needs main RunLoop; iOS doesn't spin it in background audio | `iOS/VoxKey/Services/BackgroundAudioManager.swift` |
| Audio engine always-on (orange dot) | Silence player kept process alive but timers didn't fire | `iOS/VoxKey/Services/AudioRecorder.swift` |
| NSAllowsArbitraryLoads only | NSExceptionDomains conflicts on iOS 26, both get ignored | `iOS/project.yml` → Info.plist |
| OpenCC server-side post-processing | Qwen3-ASR zh-TW output inconsistent; s2twp guarantees Taiwan vocab | `Sources/VoxKey/ChineseConverter.swift` |
| Bundled OpenCC in app bundle | DMG users have no Homebrew; app checks bundle first, falls back | `Makefile` → `bundle-opencc` target |
| Python path resolution for GUI apps | macOS GUI apps have stripped PATH; `/usr/bin/python3` != user's Python | `Sources/VoxKey/IOSServerManager.swift` |

## Bundle IDs & App Group

- macOS: `com.felix.hushtype`
- iOS app: `com.felix.hushtype`
- iOS keyboard: `com.felix.hushtype.keyboard`
- App Group: `group.com.felix.voxkey` (legacy name, not renamed)
- UserDefaults suite: `com.felix.hushtype`

## Roadmap

### Active

- **iOS App UI revamp** — `iOS/VoxKey/Views/ContentView.swift` is minimal/ugly. Redesign the main app interface.
- **Go-to-market media assets** — Demo GIF (macOS workflow), iOS screenshots, comparison table. Needed for README and social sharing.
- **Floating transcription indicator (macOS)** — When Right Option is held, show a persistent floating icon/overlay near the cursor (like Typeless). Currently only the yellow system mic indicator + menu bar icon change. Dismiss after result is pasted.
- **Custom dictionary / personalization** — User-defined word corrections for recurring model errors (e.g., proper nouns, jargon). Load from a local file, apply as post-processing after OpenCC.
- **Translation mode** — One-click toggle to translate transcribed text into a target language before pasting. Could use a local model or API.

### Parking Lot

- Apple Developer Account / Notarization ($99/year) — removes Gatekeeper warning on DMG install
- GitHub Release version check on launch — parked due to privacy trade-off (adds outbound network call)
- Rename source dirs `Sources/VoxKey/` → `Sources/HushType/` — requires Package.swift + import changes across all files

### Future Ideas

- Streaming transcription — show partial text as you speak, not just after release
- Configurable hotkey — let user pick trigger key (currently hardcoded Right Option)
- Clipboard mode — copy to clipboard instead of paste-at-cursor, for apps that block paste injection
- Auto-start iOS server on launch (checkbox preference)
- LaunchAgent for start-at-login
- Session duration picker in iOS (5/15/30/60 min)
- GitHub Actions CI for build verification

## Conventions

- **Version**: semver in `Resources/Info.plist` (`CFBundleShortVersionString`). Tag format: `v0.2.1`.
- **Branching**: `feat/xxx` branch → squash-merge PR → tag + release with DMG.
- **DMG build**: `make dmg` produces `HushType.dmg`. Upload to GitHub Release via `gh release create vX.Y.Z ... HushType-bundled.dmg#HushType.dmg`.
- **DMG is gitignored**: `*.dmg` in `.gitignore`. Only lives on GitHub Releases.
- **HANDOVER.md is gitignored**: local reference only.
- **Co-author**: All commits include `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>`.
