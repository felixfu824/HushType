# HushType — AI Agent Setup Instructions

> **For non-technical users:** Copy everything below this line and paste it into your AI coding agent (Claude Code, Cursor, Codex, Windsurf, etc.). The agent will handle the entire setup process for you.

---

## Instructions for the AI Agent

You are helping a user set up HushType, a local voice-to-text app for macOS and iOS. The user may have little to no technical experience. Guide them through each step, explain what you're doing, and verify each step succeeds before moving on.

### Context

HushType is a voice-to-text tool that runs entirely on the user's Mac (Apple Silicon required). It uses the Qwen3-ASR speech model via MLX for on-device transcription. It supports mixed English/Chinese input and outputs Traditional Chinese.

There are two modes:
1. **macOS mode**: Menu bar app. User holds Right Option key, speaks, releases, text appears at cursor.
2. **iOS mode** (optional): iPhone keyboard extension that sends audio to the Mac for transcription. Requires the Mac to be running as a server.

### Task: Set up HushType on this machine

Please execute the following steps in order. After each step, verify it succeeded. If any step fails, diagnose and fix before continuing.

#### Phase 1: Prerequisites

1. Verify this is an Apple Silicon Mac:
```bash
uname -m
# Must output: arm64
```

2. Verify macOS version is 15.0+:
```bash
sw_vers --productVersion
```

3. Install Homebrew if not present:
```bash
which brew || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

4. Install required packages:
```bash
brew install opencc
```

#### Phase 2: Build and install the macOS app

5. Clone the repository:
```bash
cd ~/Desktop
git clone https://github.com/felixfu824/HushType.git
cd HushType
```

6. Build and install:
```bash
make install
```
This compiles the app and copies it to /Applications/HushType.app. The first build downloads the speech-swift dependency (~675 MB model weights will be downloaded on first launch).

7. If the build fails with "MLX error: Failed to load the default metallib", run:
```bash
bash scripts/build_mlx_metallib.sh release
make install
```

8. Launch the app:
```bash
open /Applications/HushType.app
```

9. **Ask the user to do these manually** (cannot be automated):
   - A dialog will ask for Accessibility permission. Tell the user: "Go to System Settings > Privacy & Security > Accessibility, and make sure HushType is checked."
   - A dialog will ask for Microphone permission. Tell the user: "Click Allow."
   - Wait for the model to download (progress shows in the menu bar). Tell the user: "Wait until the menu bar shows 'Ready'."

10. Test it:
    - Tell the user: "Hold down the Right Option key (the Option key on the right side of your keyboard), say something, then release the key. The text should appear where your cursor is."

**macOS setup is now complete.** If the user only wants macOS, stop here.

---

#### Phase 3: iOS setup (optional — only if user wants iPhone support)

11. Install additional dependencies:
```bash
pip3 install "mlx-audio[stt,server]" webrtcvad-wheels setuptools httpx
brew install xcodegen
```

If `pip3` is not found:
```bash
brew install python
pip3 install "mlx-audio[stt,server]" webrtcvad-wheels setuptools httpx
```

12. Verify Xcode is installed:
```bash
xcode-select -p
# Should output a path like /Applications/Xcode.app/Contents/Developer
```
If not installed, tell the user: "Please install Xcode from the Mac App Store first. It's a large download (~30 GB)."

13. Generate the iOS Xcode project:
```bash
cd ~/Desktop/HushType/iOS
xcodegen generate
```

14. **The remaining iOS steps require the user to work in Xcode.** Give them these instructions:

Tell the user:
> "Now I need you to do a few things in Xcode:
>
> a) I'm opening the project for you now."

```bash
open HushType.xcodeproj
```

> "b) In Xcode, click 'HushType' in the left sidebar, then click the 'HushType' target.
> Go to 'Signing & Capabilities' and set 'Team' to your Apple ID.
> Do the same for the 'HushTypeKeyboard' target.
>
> c) Connect your iPhone with a USB cable.
>
> d) At the top of Xcode, select your iPhone as the destination (instead of 'Any iOS Device').
>
> e) Press Cmd+R to build and run.
>
> f) If Xcode asks to 'Update to recommended settings', click 'Perform Changes'.
>
> g) If the build fails with 'Failed to install', make sure your iPhone screen is unlocked."

15. **iPhone setup.** Tell the user to do these on their iPhone:

> "On your iPhone:
>
> a) If you haven't already: Go to Settings > Privacy & Security > Developer Mode > turn it On. Your phone will restart.
>
> b) After restart: Settings > General > VPN & Device Management > tap your Apple ID > tap Trust.
>
> c) Settings > General > Keyboard > Keyboards > Add New Keyboard > scroll down and tap 'HushType'.
>
> d) **Important**: Tap 'HushType' in the keyboard list > turn on 'Allow Full Access' > confirm. Without this, the keyboard won't work.
>
> e) Open the HushType app on your iPhone.
>
> f) You need your Mac's IP address."

16. Get the Mac's IP address:
```bash
# Try Tailscale first (if installed):
tailscale ip -4 2>/dev/null || ipconfig getifaddr en0
```
Tell the user the IP address and say: "Enter this in the HushType app on your iPhone as: http://[IP]:8000"

17. Start the iOS server on Mac:
Tell the user: "Click the HushType icon in your Mac's menu bar, then click 'Start iOS Server'. Wait about 20 seconds."

Verify the server is running:
```bash
curl -s http://localhost:8000/ | head -1
# Should return JSON with "status":"ok"
```

18. Tell the user to test on iPhone:
> "In the HushType app on your iPhone:
> a) Tap 'Test Connection' — it should show green 'Connected'.
> b) Tap 'Start Listening' — you'll see an orange dot at the top of your screen.
> c) Switch to Notes or any text app.
> d) Long-press the globe key on your keyboard and select 'HushType'.
> e) Tap the microphone, say something, then tap stop.
> f) Your text should appear!"

---

### Troubleshooting

If any step fails, here are common fixes:

- **`make install` fails**: Try `swift build -c release --disable-sandbox 2>&1 | tail -20` to see the actual error.
- **iPhone shows "Could not connect"**: Make sure the iOS server is running on Mac (`curl http://localhost:8000/`). Make sure iPhone and Mac are on the same WiFi or both have Tailscale.
- **Keyboard mic button does nothing**: Full Access must be enabled (Settings > Keyboard > HushType > Allow Full Access).
- **App stops working after 7 days**: Free Apple ID provisioning expires. Reconnect iPhone USB, open Xcode, press Cmd+R to reinstall.
- **"App Transport Security" error on iPhone**: This should already be handled in the project. If it appears, verify `NSAllowsArbitraryLoads` is `true` in `iOS/VoxKey/Info.plist`.

### Customization

If the user wants to change the bundle ID (e.g., for their own Apple ID):
1. In `iOS/project.yml`: change all `com.felix.hushtype` to `com.<their-name>.hushtype`
2. In `iOS/Shared/AppGroupConstants.swift`: change `group.com.felix.hushtype` to `group.com.<their-name>.hushtype`
3. Regenerate: `cd iOS && xcodegen generate`
