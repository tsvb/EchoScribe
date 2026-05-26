# 🎙️ EchoScribe — macOS Native App Testing Guide

This directory contains the native Swift & SwiftUI implementation of the **EchoScribe Meeting Assistant**. Because this application requires specific macOS privacy permissions to access your microphone and system Reminders, it is recommended to run and test it using **Xcode**.

---

## 🛠️ Step-by-Step Testing Guide

### 1. Open Xcode
Ensure you have Xcode installed (available for free on the Mac App Store).

### 2. Create a New macOS App Project
1. Open Xcode and select **File > New > Project...** (or press `Cmd + Shift + N`).
2. Select the **macOS** tab at the top and select **App**, then click **Next**.
3. Fill in the project details:
   * **Product Name**: `EchoScribe`
   * **Organization Identifier**: `com.yourcompany` (e.g., `com.echoscribe`)
   * **Interface**: `SwiftUI`
   * **Language**: `Swift`
4. Click **Next** and save the project in a directory of your choice.

### 3. Import Swift Files
1. In Xcode's left sidebar (the Project Navigator), locate and **delete** the default `ContentView.swift` and `EchoScribeApp.swift` (move them to Trash).
2. Drag and drop the 6 Swift files from this `macos-native/` directory directly into the Xcode Project Navigator:
   * `EchoScribeApp.swift`
   * `ContentView.swift`
   * `AudioRecorderManager.swift`
   * `SpeechTranscriptionManager.swift`
   * `GeminiClient.swift`
   * `EventKitManager.swift`
3. Check **"Copy items if needed"** and click **Finish**.

### 4. Configure Privacy Permissions (Critical)
To prevent the operating system from shutting down the app when accessing the microphone or EventKit, you must declare usage descriptions:
1. Select the top-level `EchoScribe` project icon in the Project Navigator.
2. Select the `EchoScribe` target under **Targets** in the main editor.
3. Select the **Info** tab at the top.
4. Hover over any row, click the **`+`** icon, and add the following two keys:
   * **Privacy - Microphone Usage Description**: Set the value to `This application requires microphone access to record meeting audio.`
   * **Privacy - Reminders Usage Description**: Set the value to `This application requires reminders access to synchronize meeting action items.`

### 5. Build and Run
* Press **`Cmd + R`** (or click the Play icon in the top left of Xcode).
* The application will compile and launch the premium glassmorphic interface natively!
