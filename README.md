# 🤖 andross

一個專為 macOS Apple Silicon (M1/M2/M3/M4) 使用者設計的極輕量、純淨 Android 虛擬機管理器。
藉此您可以完全擺脫實體 Android/iPhone 手機，直接在 Mac 上運行獨立的 LINE 帳號或測試各類 APK 檔案。

---

## ✨ 特色
*   **極致輕巧**：完全不需要安裝幾 GB 的 Android Studio 整合開發環境，只下載 Google 官方的核心模擬引擎。
*   **原生硬體加速**：直接利用 macOS 的 `Hypervisor.framework`，1:1 調用 M2/M3/M4 晶片效能。
*   **自主權**：
    *   可選擇安裝含有 Google Play 的版本（方便使用需要 GMS 的 App）。
    *   可選擇 100% 純淨開源的 AOSP 版（無 Google 服務，可用 Aurora Store 安全下載 Play 商店 App）。
    *   全空白沙盒版（僅支援手動拖放本地 APK 安裝）。

---

## 🚀 快速開始

### 1. 建立第一台虛擬手機
在專案目錄下執行以下指令，系統會自動檢查 Java 與 SDK 依賴環境（如果缺失會引導透過 Homebrew 安裝）：
```bash
./andross setup
```
依指示輸入名稱（例如 `line-personal` 或 `line-creator`），並選擇您要的系統映像檔類型。

### 2. 啟動虛擬手機
```bash
./andross start <虛擬機名稱>
```

### 3. 安裝 APK
啟動虛擬手機後，您可以：
*   **拖放法**：直接將 `.apk` 檔案用滑鼠拖入彈出的虛擬手機視窗中，或者直接拖入 **andross.app** 視窗的安裝區中。
*   **指令法**：
    ```bash
    ./andross install /path/to/your-app.apk
    ```

### 4. 關閉所有虛擬手機
完成登入或驗證後，可以一鍵關閉所有背景運行的模擬器，徹底釋放 Mac 記憶體：
```bash
./andross stop
```

### 5. 列出所有已建立的虛擬手機
```bash
./andross list
```
