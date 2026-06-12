# 🤖 andross

一個專為 macOS Apple Silicon (M1/M2/M3/M4) 使用者設計的極輕量、純淨 Android 虛擬機管理器。
不需要實體 Android 手機，就能在 Mac 上替任何「一帳號綁一裝置」的 App（LINE、通訊軟體、遊戲⋯）多開獨立帳號，或安全測試各類 APK 檔案。

---

## ✨ 特色
*   **極致輕巧**：完全不需要安裝幾 GB 的 Android Studio 整合開發環境，只透過 Homebrew 下載 Google 官方的核心模擬引擎。
*   **原生硬體加速**：直接利用 macOS 的 `Hypervisor.framework`，1:1 調用 M 系列晶片效能。
*   **身分沙盒（Sandboxes）**：用 Android 原生多使用者機制，在同一台虛擬手機裡建立多個完全隔離的身分，App 一鍵克隆、各登各的帳號。
*   **自主權**：
    *   可選擇安裝含有 Google Play 的版本（方便使用需要 GMS 的 App）。
    *   可選擇 100% 純淨開源的 AOSP 版（無 Google 服務，可用 Aurora Store 安全下載 Play 商店 App）。
    *   全空白沙盒版（僅支援手動拖放本地 APK 安裝）。

---

## 🚀 快速開始

### 1. 打包 andross.app（免 Xcode）
```bash
./scripts/build-app.sh
```
完成後會在 `~/Applications/andross.app` 產生可雙擊的 App（第一次開啟若被 macOS 警告未簽章，右鍵 → 打開）。

### 2. 在 App 裡完成所有事
*   **Devices**：建立第一台虛擬手機（自動檢查並引導安裝 Java 與 Android SDK 依賴）、一鍵啟動／刪除。
*   **Sandboxes**：建立、切換、刪除隔離身分，App 一鍵克隆到新身分。
*   **Installer**：把 `.apk` 直接拖進視窗安裝；也可以拖進虛擬手機視窗。
*   **Storage**：檢視 Mac 端與 Android 端各佔多少空間。
*   **Settings**：依賴狀態、停止所有模擬器、乾淨解除安裝精靈（含 Homebrew 元件）。

---

## 🛠 開發
```bash
./scripts/test.sh              # 建置 + 單元測試（零依賴 runner）
./scripts/test.sh integration  # 真的 headless 開機一台 AVD，走完身分生命週期（需已建 AVD，耗時數分鐘）
./scripts/make-icon.sh         # 重新產生 App icon（assets/andross.icns）
```

## 📌 誠實邊界
*   LINE 等服務註冊**仍需要一個可收驗證的電話號碼**——andross 省掉的是「多一支手機」，不是「電話號碼」。
*   LINE 一個帳號同時只能登入一支手機裝置；andross 適合經營**新的／副的**帳號，不是把現有手機帳號搬過來。
