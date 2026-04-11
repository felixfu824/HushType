<p align="center">
  <img src="Resources/HushType.png" width="128" height="128" alt="HushType icon">
</p>

<h1 align="center">HushType</h1>

<p align="center">
  macOS 與 iOS 的本地語音轉文字工具。<br>
  隨意混用語言說話，文字即刻出現在游標位置。無雲端、無訂閱。
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-TW.md">繁體中文</a>
</p>

---

## 為什麼選擇 HushType

**隱私與安全。** 你的語音永遠不會離開你的網路。語音模型完全在你 Mac 的 GPU 上運行——無雲端 API、無帳號、無資料蒐集。iPhone 的音訊透過 Tailscale（WireGuard 加密）或區域網路傳送到你自己的 Mac，沒有任何第三方能接觸到你的資料。

**真正能用的繁體中文。** OpenAI 的 Whisper 只提供單一的 "zh" 語言代碼，預設輸出簡體中文，且沒有可靠的方法強制輸出繁體。開源模型常常混雜簡體字或使用大陸用語。HushType 使用 Qwen3-ASR 進行語音辨識，再透過 OpenCC（s2twp）進行簡繁轉換，確保穩定的繁體輸出與台灣在地用語（例如「軟體」而非「软件」）。

**多語言混用。** 在同一句話中混用英文和中文——HushType 一次搞定。Apple 內建聽寫需要手動切換語言。Qwen3-ASR 原生支援語言混用，且效能可媲美體積大三倍的模型。

**輕量。** 約 675 MB 儲存空間、約 2.2 GB 尖峰記憶體。任何 Apple Silicon Mac 都能在正常工作的同時輕鬆運行。10 秒的語音約 1 秒即可完成轉錄。

### 使用情境

**與 AI 助手對話：** 要給 Claude 或 ChatGPT 一段詳細的 prompt——需求、限制、背景脈絡——打字要 5 分鐘，用說的只要 30 秒。在 iPhone 的 HushType 鍵盤上按麥克風，自然地說出來（可混用語言），按停止——文字立刻出現在聊天輸入框中。

**通勤時的語音筆記：** 在捷運上，Mac 在家裡。在 iPhone 上按「開始聆聽」，切到備忘錄，按麥克風。語音透過 Tailscale 傳回你的 Mac，約 1 秒完成轉錄，文字出現。

---

## 運作原理

```
macOS（獨立運作——不需要網路）：
  按住 Right Option → 說話 → 放開 → 文字出現在游標位置
  流程：麥克風 → Qwen3-ASR（MLX，裝置端推論）→ OpenCC s2twp → 貼上

iOS（透過你的 Mac 作為伺服器）：
  開啟 HushType → 開始聆聽 → 切到任何 App → HushType 鍵盤 → 按麥克風
  流程：iPhone 麥克風 → WiFi/Tailscale → Mac 伺服器 → Qwen3-ASR → OpenCC → 結果回傳 → 文字插入
```

```
                                     ┌──────────────────────────────────┐
                                     │  Mac (Apple Silicon)             │
  ┌──────────────┐   WiFi/Tailscale  │                                  │
  │ iPhone       │ ──── HTTP POST ──►│  ios_server.py (port 8000)       │
  │ HushType KB  │◄── JSON result ───│    ↓                             │
  └──────────────┘                   │  mlx-audio (port 8199)           │
                                     │    → Qwen3-ASR 0.6B (MLX/Metal) │
                                     │    → OpenCC s2twp                │
                                     │                                  │
                                     │  HushType.app (選單列)            │
                                     │    → Right Option 快捷鍵          │
                                     │    → 本地轉錄                     │
                                     └──────────────────────────────────┘
```

---

## 安裝

### 方案 A：下載 DMG（不需要任何開發工具）

1. 從[最新版本](https://github.com/felixfu824/HushType/releases)下載 `HushType.dmg`
2. 打開 DMG，將 HushType 拖到「應用程式」
3. 右鍵點擊 HushType.app → 打開（首次啟動時需要——App 使用臨時簽章，未經 Apple 公證）
4. 授予**輔助使用**與**麥克風**權限
5. 等待模型下載（約 675 MB，僅首次，進度顯示在選單列）

DMG 為完全獨立版本——OpenCC 及所有相依套件皆已內含。不需要 Homebrew、不需要終端機指令。

> **iOS 伺服器支援：** DMG 也包含選單列中的 iOS 伺服器切換功能。需要額外安裝 Python 3 及相關套件——參見下方 [iOS 安裝指南](#安裝指南ios（iphone--mac-伺服器）)。若缺少相依套件，App 會顯示錯誤訊息及所需的 `pip3 install` 指令。

### 方案 B：從原始碼編譯

參見下方[前置需求](#前置需求與相依套件)及 [macOS 安裝指南](#安裝指南macos)。

### 方案 C：零基礎安裝

**完全不懂技術？沒問題。** 打開 [AGENT_SETUP.md](AGENT_SETUP.md)，複製全部內容，貼到任何 AI 程式助手中——[Claude Code](https://claude.ai/code)、[Cursor](https://cursor.com)、[Codex](https://openai.com/index/codex/) 或 [Windsurf](https://windsurf.com)。AI 助手會一步一步帶你完成整個安裝，從安裝相依套件到在你的 Mac 和 iPhone 上執行。

---

## 更新

macOS 沒有 Windows 那種「解除安裝程式」的概念——更新一個 App 就是**直接覆蓋 `.app` 資料夾**。你的偏好設定、下載好的 ASR 模型、以及其他使用者資料都存在 `.app` 外面，覆蓋的時候不會被動到。

**更新 HushType（DMG 使用者）：**

1. **退出 HushType** — 選單列圖示 → Quit HushType。正在執行中的 App 沒辦法被 Finder 覆蓋。
2. **從 [latest release](https://github.com/felixfu824/HushType/releases) 下載新的 `HushType.dmg`**。
3. **打開 DMG，把 `HushType.app` 拖到視窗內的 `Applications` 捷徑上**。Finder 會跳出：「名為 HushType.app 的項目已存在。要取代嗎？」點 **取代 / Replace**。
4. **從 Spotlight 啟動 HushType**。新版本首次啟動時，HushType 會自動清除舊版本留下的輔助使用權限記錄（舊版的程式碼雜湊值），然後重新顯示 onboarding 歡迎對話框。照著流程走一次：在系統設定 → 隱私權與安全性 → 輔助使用 中把 HushType 開關打開，然後在對話框點 **Restart HushType**。每次更新只需要做一次這個動作。

**從原始碼編譯的使用者：** 直接 `git pull && make install` 就搞定。新編譯出的 binary 會有新的程式碼雜湊，所以一樣需要重新授權輔助使用一次。

**為什麼每次更新都要重新授權？** HushType 目前是 ad-hoc 簽章（沒有 Notarization）。macOS 的權限資料庫對 ad-hoc 簽章的 App 是用 **程式碼雜湊值（cdhash）** 來追蹤的，而 cdhash 在每次重新編譯後都會改變。正式的 Developer ID 簽章（需要付費 Apple Developer 帳號）可以解決這個問題。在那之前，HushType 會在啟動時自動清理舊的 entry，讓你只要重按一次開關就好，不用手動去找哪個是舊的、哪個是新的。

**完全解除安裝 HushType：**

1. 退出 HushType
2. 把 `/Applications/HushType.app` 拖到垃圾桶
3. *(可選)* 移除偏好設定：`defaults delete com.felix.hushtype`
4. *(可選)* 移除下載的模型：`rm -rf ~/.cache/huggingface/hub/models--mlx-community--Qwen3-ASR*`
5. *(可選)* 移除輔助使用權限紀錄：系統設定 → 隱私權與安全性 → 輔助使用 → 選 HushType → 點 `-` 按鈕

---

## 前置需求與相依套件

> **注意：** 若你使用 DMG 安裝（方案 A），可跳過此段——所有相依套件皆已內含。以下僅適用於從原始碼編譯或設定 iOS 伺服器。

**硬體與系統：**

| 需求 | 用途 |
|---|---|
| Apple Silicon Mac（M1 以上）| MLX 推論需要 Metal GPU |
| macOS 15.0+ | speech-swift 最低版本需求 |
| iPhone（iOS 17+）| iOS 客戶端（選用）|

**軟體相依套件（從原始碼編譯）：**

| 套件 | 用途 | 安裝方式 | 需要於 |
|---|---|---|---|
| [Homebrew](https://brew.sh) | 套件管理器 | 見 brew.sh | 從原始碼編譯 |
| [opencc](https://formulae.brew.sh/formula/opencc) | 簡體 → 繁體中文 | `brew install opencc` | 從原始碼編譯（DMG 已內含）|
| [speech-swift](https://github.com/soniqo/speech-swift) | Apple Silicon 上的 Qwen3-ASR（MLX）| SPM 自動安裝 | 從原始碼編譯 |
| [Python 3.13+](https://python.org) | iOS 伺服器執行環境 | `brew install python` | 僅 iOS |
| [mlx-audio](https://github.com/Blaizzy/mlx-audio) | iOS 用的 STT 伺服器 | `pip3 install "mlx-audio[stt,server]"` | 僅 iOS |
| [httpx](https://www.python-httpx.org/) | 代理伺服器用的非同步 HTTP | `pip3 install httpx` | 僅 iOS |
| webrtcvad-wheels, setuptools | mlx-audio 執行相依 | `pip3 install webrtcvad-wheels setuptools` | 僅 iOS |
| [xcodegen](https://github.com/yonaskolb/XcodeGen) | iOS Xcode 專案產生器 | `brew install xcodegen` | 僅 iOS |
| [Xcode 16+](https://developer.apple.com/xcode/) | 編譯 iOS App | Mac App Store | 僅 iOS |
| [Tailscale](https://tailscale.com) | 加密的 iPhone-to-Mac 連線 | 見 tailscale.com | 選用 |

---

## 安裝指南：macOS

### 步驟 1：下載與編譯

```bash
git clone https://github.com/felixfu824/HushType.git
cd HushType

# 安裝相依套件
brew install opencc

# 編譯並安裝到 /Applications
make install
```

### 步驟 2：啟動並授予權限

1. 從 Spotlight 啟動 HushType（Cmd+Space → HushType）
2. 首次啟動時會跳出**歡迎視窗**，說明 HushType 需要的權限。點擊 **Get Started**。
3. 系統設定會自動打開到輔助使用頁面。在清單中找到 HushType 並**開啟開關**。
4. 當系統要求麥克風權限時，點擊**允許**。
5. 回到 HushType 的後續視窗，點擊 **Restart HushType** — App 會自動重新啟動，讓新授予的權限生效。（macOS 會在 process 層級快取權限檢查結果，所以授予權限後必須重啟 — HushType 會幫你處理這個步驟。）
6. 等待模型下載（約 675 MB，僅首次，進度顯示在選單列）

### 步驟 3：使用

- **按住 Right Option** — 開始錄音。螢幕底部會出現一個半透明的「Listening」指示條，顯示即時的音量條。
- **放開** — 指示條切換為脈動的「Transcribing」狀態，語音辨識完成後，文字貼到游標位置，同時也保留在剪貼簿中可再次貼上。
- **選單列圖示** — 顯示狀態（閒置 / 錄音中 / 轉錄中）
- **選單列 > Language** — 切換 Auto / English / 中文 / 日本語
- **選單列 > Show Floating Indicator** — 切換底部浮動指示條（預設開啟）

macOS 到此結束。不需要伺服器、不需要網路、不需要設定。

---

## 安裝指南：iOS（iPhone + Mac 伺服器）

iOS App 使用你的 Mac 作為轉錄伺服器。iPhone 透過 WiFi 或 Tailscale 將音訊傳送到 Mac，再接收轉錄好的文字。

### 步驟 1：在 Mac 上安裝伺服器相依套件

```bash
# 轉錄伺服器的 Python 套件
pip3 install "mlx-audio[stt,server]" webrtcvad-wheels setuptools httpx

# OpenCC（繁體中文轉換）+ xcodegen（iOS 專案產生器）
brew install opencc xcodegen
```

### 步驟 2：取得 Mac 的 IP 位址

```bash
# 使用 Tailscale（隨處皆可連線）：
tailscale ip -4
# 範例輸出：100.x.x.x

# 僅使用區域網路（同一 WiFi）：
ipconfig getifaddr en0
# 範例輸出：192.168.50.50
```

記下這個 IP，稍後會在 iPhone 上輸入。

### 步驟 3：在 Mac 上啟動 iOS 伺服器

**方法 A — 從 HushType 選單列（推薦）：**
點擊選單列的 HushType 圖示 → "Start iOS Server"

**方法 B — 從終端機：**
```bash
cd HushType
python3 scripts/ios_server.py
# 伺服器啟動在 0.0.0.0:8000
# 首次轉錄請求會下載模型（約 675 MB）
```

驗證伺服器是否運行：
```bash
curl http://localhost:8000/
# 應回傳：{"status":"ok","service":"HushType iOS Server","opencc":true}
```

### 步驟 4：編譯並安裝 iOS App

```bash
cd iOS
xcodegen generate
open HushType.xcodeproj
```

在 Xcode 中：
1. 點擊左側導覽的 **HushType** 專案
2. 選擇 **HushType** target → Signing & Capabilities → 設定 **Team** 為你的 Apple ID
3. 選擇 **HushTypeKeyboard** target → 同樣設定 **Team**
4. 如果 Xcode 顯示 "Update to recommended settings" → 點擊 **Perform Changes**
5. 用 USB 連接 iPhone
6. 選擇你的 iPhone 作為執行目標（頂部欄位）
7. 點擊 **Run**（Cmd+R）

首次編譯約需 1 分鐘，之後會更快。

### 步驟 5：設定 iPhone

以下步驟在 iPhone 上操作：

**5a. 啟用開發者模式**（僅首次）：
1. 設定 → 隱私權與安全性 → 開發者模式 → 開啟
2. iPhone 會重新啟動。重啟後確認「開啟」。

**5b. 信任開發者**（僅首次）：
1. 設定 → 一般 → VPN 與裝置管理
2. 點擊「開發者 App」下你的 Apple ID
3. 點擊**信任**

**5c. 加入 HushType 鍵盤**（僅首次）：
1. 設定 → 一般 → 鍵盤 → 鍵盤 → **新增鍵盤**
2. 往下滑到「第三方鍵盤」→ 點擊 **HushType**
3. 點擊清單中的 **HushType** → 開啟**允許完整取用** → 確認

> **重要：** 必須啟用「允許完整取用」。沒有開啟的話，鍵盤無法與主 App 通訊，也無法存取網路。如果按麥克風沒反應，這是最常見的原因。

### 步驟 6：設定與測試

1. 在 iPhone 上開啟 **HushType** App
2. 輸入 Mac 的 IP 位址：`http://<你的IP>:8000`（步驟 2 取得的 IP）
3. 點擊 **Test Connection** → 應顯示綠色 "Connected"
4. 點擊 **Start Listening** — 螢幕頂部出現橘色麥克風指示燈
5. App 顯示 5 分鐘倒數計時

### 步驟 7：開始使用

1. 切到任何 App（訊息、備忘錄、Safari 等）
2. 長按**地球鍵** → 選擇 **HushType**
3. 點擊**麥克風按鈕** → 說話 → 點擊**停止**
4. 等待 1-2 秒 → 轉錄的文字出現在游標位置
5. 使用**空白鍵**、**刪除鍵**和 **return** 進行基本編輯

5 分鐘聆聽時間到期後，回到 HushType App 再按一次「Start Listening」。

### 設定完成後：日常使用

每天只需重複步驟 3 + 6-7：
1. 確認 Mac 上的 iOS 伺服器已啟動（選單列 → "Start iOS Server"）
2. 在 iPhone 開啟 HushType → Start Listening
3. 切到你的 App → 使用鍵盤

USB 線只在安裝/更新 App 時需要。日常使用完全無線。

> **注意：** 使用免費 Apple ID 佈署，App 每 7 天會過期。停止運作時，重新接上 USB → Xcode → Cmd+R 重新安裝即可。設定會保留。付費 Apple Developer 帳號（US$99/年）可延長至 1 年。

---

## 設定

### macOS

```bash
# 檢視所有設定
defaults read com.felix.hushtype

# 語言：nil=自動, "english", "chinese", "japanese"
defaults write com.felix.hushtype hushtype.language -string "chinese"

# 模型：預設 0.6B-4bit，可選 1.7B 以獲得更好品質
defaults write com.felix.hushtype hushtype.modelId -string "mlx-community/Qwen3-ASR-1.7B-8bit"

# 繁體中文轉換（預設：true）
defaults write com.felix.hushtype hushtype.chineseConversionEnabled -bool false

# 底部浮動「Listening / Transcribing」指示條（預設：true）
defaults write com.felix.hushtype hushtype.floatingOverlayEnabled -bool false
```

### iOS

- 伺服器網址：在 App 介面中設定（儲存在 App Group）
- 聆聽時間：5 分鐘（寫在 BackgroundAudioManager.swift 中）
- 模型：`mlx-community/Qwen3-ASR-0.6B-4bit`（寫在 RemoteTranscriber.swift 中）

### 更改快捷鍵（macOS）

編輯 `Sources/HushType/HotkeyManager.swift`：
```swift
private static let rightOptionKeyCode: Int64 = 61
```

常用鍵碼：Right Option (61)、Right Command (54)、Left Option (58)、Left Control (59)、Fn/Globe (63)。

---

## 疑難排解

**macOS：「MLX error: Failed to load the default metallib」**
執行：`bash scripts/build_mlx_metallib.sh release`

**macOS：快捷鍵沒反應**
檢查系統設定 → 隱私權與安全性 → 輔助使用。HushType 必須在清單中且開關要打開。如果你剛授予權限但快捷鍵仍然沒反應，請退出並重新啟動 HushType — macOS 會在 process 層級快取權限檢查結果，授予權限後必須重啟才會生效。首次啟動的 onboarding 流程會自動處理這個步驟，但如果你是透過其他方式到達這個狀態，就需要手動重啟。

**iOS：「App Transport Security」錯誤**
Info.plist 中必須有 `NSAllowsArbitraryLoads = true`，且**不能**同時有 `NSExceptionDomains`——兩者衝突時 iOS 會忽略全域允許。

**iOS：按麥克風沒反應**
最常見的原因：**沒有啟用「允許完整取用」**。前往設定 > 一般 > 鍵盤 > 鍵盤 > HushType > 開啟「允許完整取用」。

**iOS：鍵盤卡在「Transcribing...」**
主 App 沒有收到指令。請確認：
1. HushType App 正在運行且顯示「Listening」（有橘色麥克風指示燈）
2. Mac 伺服器正在運行（`curl http://<mac-ip>:8000/`）
3. App Group 容器可用（在 Xcode 主控台檢查 "App Group container: /path..."）

**iOS：「Open HushType app first」**
主 App 未運行或聆聽時間已到期（5 分鐘）。開啟 HushType App 並再次點擊「Start Listening」。

**iOS：App 7 天後無法開啟**
免費佈署的簽署已過期。重新接上 USB → Xcode → Cmd+R 重新安裝。設定會保留。

**伺服器：Port 已被占用**
```bash
lsof -ti :8000 :8199 | xargs kill
```

---

## 隱私與安全

- **不儲存任何錄音。** 語音資料僅存在於記憶體中（錄音 → 轉錄流程），完成後即丟棄。無論 macOS 或 iOS 伺服器，皆不會將任何音訊寫入磁碟。
- **設定完成後不需要網路。** 唯一需要連網的是首次啟動時下載模型（約 675 MB）。之後，App 與模型完全離線運行，零對外連線。
- **無遙測。** 無分析追蹤、無使用統計、無回傳機制。macOS App 除了初始模型下載（由 speech-swift 內的 HuggingFace Hub SDK 處理）外，不包含任何網路程式碼。
- **iOS 音訊留在你的網路中。** iPhone 音訊直接傳送到你的 Mac，透過區域網路 WiFi 或 Tailscale（WireGuard 加密）。不經過任何第三方伺服器。
- **可完全離網運作。** 在另一台電腦上預先下載模型資料夾（`~/.cache/huggingface/hub/models--mlx-community--Qwen3-ASR-0.6B-4bit/`），複製過來即可——App 將永遠不需要網路。

---

## 已知限制

- iOS 需要 Mac 開機且伺服器運行中（無雲端備援）
- 免費佈署：iOS App 每 7 天過期（需透過 Xcode 重新簽署）
- 聆聽時間固定為 5 分鐘（尚無介面可調整）
- Mac 必須是 iPhone 可連線的（同一 WiFi 或 Tailscale）
- DMG 使用臨時簽章（未經 Apple 公證）——首次啟動時 macOS Gatekeeper 會發出警告，需右鍵 → 打開來略過

