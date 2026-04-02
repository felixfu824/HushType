# VoxKey

Local voice-to-text input for macOS. Hold a key, speak, release — transcribed text appears at your cursor. Handles mixed English/Chinese with Traditional Chinese output.

## Quick Start

```bash
# Build + install to /Applications (launch from Spotlight: Cmd+Space → VoxKey)
make install

# Or run from terminal (shows debug logs)
make run
```

Other make targets:
- `make build` — compile only
- `make bundle` — create VoxKey.app in project folder
- `make install` — build + copy to /Applications (Spotlight-launchable)
- `make uninstall` — remove from /Applications
- `make clean` — remove build artifacts

**First launch requirements:**
1. Grant **Accessibility** permission (System Settings > Privacy & Security > Accessibility)
2. Grant **Microphone** permission when prompted
3. Wait for model download (~675 MB, one-time)

## Usage

- **Hold Right Option** — start recording (menu bar icon changes)
- **Release** — transcribe and paste at cursor
- **Menu bar icon** — shows status (idle/recording/transcribing)
- **Menu bar > Language** — switch between Auto/English/Chinese/Japanese

## Configuration

All settings are stored in `UserDefaults` (domain: `com.felix.voxkey`). Change via terminal:

```bash
# View all settings
defaults read com.felix.voxkey

# Change language (nil=auto, "english", "chinese", "japanese")
defaults write com.felix.voxkey voxkey.language -string "chinese"
defaults delete com.felix.voxkey voxkey.language   # reset to auto

# Change model (default: 0.6B-4bit, alternative: 1.7B-8bit for better accuracy)
defaults write com.felix.voxkey voxkey.modelId -string "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"

# Toggle Traditional Chinese conversion (default: true)
defaults write com.felix.voxkey voxkey.chineseConversionEnabled -bool false
```

Restart VoxKey after changing settings.

## Changing the Hotkey

Edit `Sources/VoxKey/HotkeyManager.swift`, line with:
```swift
private static let rightOptionKeyCode: Int64 = 61
```

Common keycodes:
| Key | Keycode |
|-----|---------|
| Right Option | 61 |
| Right Command | 54 |
| Left Option | 58 |
| Left Control | 59 |
| Fn/Globe | 63 |

After changing, rebuild: `make build`

## Architecture

```
main.swift              Entry point (NSApplication bootstrap)
    |
AppDelegate.swift       Orchestrator + state machine (idle/recording/transcribing/inserting)
    |
    +-- StatusBarController.swift   Menu bar icon + language menu
    +-- HotkeyManager.swift         CGEvent tap for Right Option key
    +-- AudioCaptureService.swift    AVAudioEngine mic capture (16kHz mono)
    +-- TranscriptionEngine.swift    Protocol + Qwen3ASR wrapper
    |       +-- ChineseConverter.swift   OpenCC s2twp (Simplified -> Traditional)
    +-- TextInserter.swift           Clipboard + simulated Cmd+V paste
    +-- InputSourceManager.swift     CJK input method detection/switching
    +-- AppConfig.swift              UserDefaults wrapper
```

**Pipeline flow:**
```
Hold key -> AudioCaptureService.startRecording()
Release  -> AudioCaptureService.stopRecording() -> [Float] samples
         -> TranscriptionEngine.transcribe(audio, language)
            -> Qwen3ASRModel.transcribe()     // MLX inference on GPU
            -> ChineseConverter.convert()      // S->T if needed
         -> TextInserter.insert(text)
            -> save clipboard -> set text -> Cmd+V -> restore clipboard
```

## Dependencies

| Dependency | Purpose | Size |
|------------|---------|------|
| [speech-swift](https://github.com/soniqo/speech-swift) | Qwen3-ASR on Apple Silicon (MLX) | ~675 MB model weights |
| [opencc](https://formulae.brew.sh/formula/opencc) | Simplified -> Traditional Chinese | ~2 MB (`brew install opencc`) |

## Troubleshooting

**"MLX error: Failed to load the default metallib"**
Run: `bash scripts/build_mlx_metallib.sh release`

**"Metal Toolchain is missing"**
Run: `xcodebuild -downloadComponent MetalToolchain`

**Hotkey not working**
Check Accessibility permission: System Settings > Privacy & Security > Accessibility. VoxKey (or Terminal, if running from terminal) must be listed.

**No audio captured**
Check Microphone permission: System Settings > Privacy & Security > Microphone.

**Transcription is empty or garbage**
- Recording too short (< 0.3s) is auto-skipped
- Check terminal output for `[VoxKey]` debug logs
- Try switching language in menu bar (Auto may misdetect)

**Text not pasting into target app**
- Accessibility permission must be granted
- Some apps (e.g., password fields) block programmatic paste
- Terminal output shows `[TextInserter] Clipboard now:` — verify text is there

## Files

```
VoxKey/
├── Package.swift              SPM config (speech-swift dependency)
├── Makefile                   build / run / bundle / clean
├── README.md                  This file
├── scripts/
│   └── build_mlx_metallib.sh  Compiles MLX Metal shaders
├── Sources/VoxKey/            All Swift source (10 files)
└── Resources/
    └── Info.plist             LSUIElement, mic usage description
```
