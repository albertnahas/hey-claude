// Hey Claude: listens on-device for "Hey Claude" / "Hello Claude" and runs the bundled
// hey-claude.sh (screenshot → Claude Code in tmux → terminal window attached to it).

import AVFoundation
import AppKit
import ServiceManagement
import Speech
import SwiftUI

private let home = FileManager.default.homeDirectoryForCurrentUser
private let logURL = home.appendingPathComponent("Library/Logs/HeyClaude.log")
private let configURL = home.appendingPathComponent(".config/hey-claude/config.env")
private let defaultWakePattern = #"\b(hey|hello)\W+(claude|claud|clawed|cloud|clyde)\b"#

private let logHandle: FileHandle = {
  if !FileManager.default.fileExists(atPath: logURL.path) {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
  }
  let handle = try! FileHandle(forWritingTo: logURL)
  handle.seekToEndOfFile()
  return handle
}()

func log(_ message: String) {
  logHandle.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
}

/// Reads one KEY=value entry from the shell-style config file.
func configValue(_ key: String) -> String? {
  guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
  for line in text.split(separator: "\n") where line.hasPrefix("\(key)=") {
    let value = line.dropFirst(key.count + 1)
    if let quote = value.first, quote == "'" || quote == "\"", value.count >= 2, value.last == quote {
      return String(value.dropFirst().dropLast())
    }
    return String(value)
  }
  return nil
}

// MARK: - Wake-phrase listener

final class WakeListener {
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var rotation: Timer?
  private var wakePattern = try! NSRegularExpression(pattern: defaultWakePattern, options: .caseInsensitive)
  private let onWake: () -> Void

  init(onWake: @escaping () -> Void) { self.onWake = onWake }

  func start() throws {
    let input = engine.inputNode
    input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) {
      [weak self] buffer, _ in
      guard let self else { return }
      self.lock.lock()
      self.request?.append(buffer)
      self.lock.unlock()
    }
    engine.prepare()
    try engine.start()
    beginTask()
    log("listening (on-device: \(recognizer.supportsOnDeviceRecognition))")
  }

  func stop() {
    rotation?.invalidate()
    task?.cancel()
    swapRequest(nil)
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    log("stopped")
  }

  private func swapRequest(_ new: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock()
    request?.endAudio()
    request = new
    lock.unlock()
  }

  private func reloadWakePattern() {
    do {
      wakePattern = try NSRegularExpression(
        pattern: configValue("WAKE_PATTERN") ?? defaultWakePattern, options: .caseInsensitive)
    } catch {
      log("invalid WAKE_PATTERN, keeping the previous one: \(error)")
    }
  }

  // One recognition task at a time, rotated every 50 s so transcripts stay short (and config
  // edits apply), and after every detection so the same utterance never fires twice.
  private func beginTask() {
    task?.cancel()
    reloadWakePattern()
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    req.shouldReportPartialResults = true
    req.contextualStrings = ["Claude", "Hey Claude", "Hello Claude"]
    swapRequest(req)
    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      DispatchQueue.main.async { self?.handle(req, result, error) }
    }
    rotation?.invalidate()
    rotation = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
      self?.beginTask()
    }
  }

  private func handle(
    _ req: SFSpeechAudioBufferRecognitionRequest, _ result: SFSpeechRecognitionResult?,
    _ error: Error?
  ) {
    guard req === request else { return }  // late callback from a rotated-out task
    if let text = result?.bestTranscription.formattedString,
      wakePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    {
      log("wake: \(text)")
      beginTask()
      onWake()
    } else if result?.isFinal == true || error != nil {
      // The recognizer ends a task after long silence; restart after a beat to avoid a hot loop.
      swapRequest(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self, self.request == nil, self.engine.isRunning else { return }
        self.beginTask()
      }
    }
  }
}

// MARK: - State

final class AppModel: ObservableObject {
  @Published var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
    didSet {
      UserDefaults.standard.set(enabled, forKey: "enabled")
      applyListening()
    }
  }
  @Published var openAtLogin = SMAppService.mainApp.status == .enabled {
    didSet {
      do {
        try openAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
      } catch { log("login item: \(error)") }
    }
  }
  private(set) var running = false
  var onChange: () -> Void = {}

  private lazy var listener = WakeListener { [weak self] in self?.wake() }
  private var busy = false

  func applyListening() {
    if enabled, !running {
      do {
        try listener.start()
        running = true
      } catch { log("start failed: \(error)") }
    } else if !enabled, running {
      listener.stop()
      running = false
    }
    onChange()
  }

  func openConfig() { NSWorkspace.shared.open(configURL) }
  func showLog() { NSWorkspace.shared.open(logURL) }

  private func wake() {
    guard !busy else { return }
    busy = true
    let process = Process()
    process.executableURL = Bundle.main.url(forResource: "hey-claude", withExtension: "sh")
    process.arguments = [String(NSScreen.screens.count)]
    process.standardOutput = logHandle
    process.standardError = logHandle
    process.terminationHandler = { p in
      DispatchQueue.main.async {
        log("hey-claude.sh exited \(p.terminationStatus)")
        self.busy = false
      }
    }
    do { try process.run() } catch {
      log("launch failed: \(error)")
      busy = false
    }
  }
}

// MARK: - UI

struct SettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Toggle("Listen for \u{201C}Hey Claude\u{201D} / \u{201C}Hello Claude\u{201D}", isOn: $model.enabled)
      Toggle("Open at login", isOn: $model.openAtLogin)
      HStack {
        Button("Edit configuration…", action: model.openConfig)
        Button("Show log", action: model.showLog)
      }
    }
    .padding(20)
    .frame(width: 380)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let model = AppModel()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private lazy var settingsWindow: NSWindow = {
    let window = NSWindow(
      contentViewController: NSHostingController(rootView: SettingsView(model: model)))
    window.title = "Hey Claude"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    return window
  }()

  func applicationDidFinishLaunching(_ notification: Notification) {
    installDefaultConfig()
    if !UserDefaults.standard.bool(forKey: "launchedBefore") {
      UserDefaults.standard.set(true, forKey: "launchedBefore")
      model.openAtLogin = true
    }

    let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    settings.target = self
    let menu = NSMenu()
    menu.addItem(settings)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Hey Claude", action: #selector(NSApp.terminate), keyEquivalent: "q"))
    statusItem.menu = menu
    model.onChange = { [weak self] in self?.refreshIcon() }
    refreshIcon()

    SFSpeechRecognizer.requestAuthorization { status in
      AVCaptureDevice.requestAccess(for: .audio) { mic in
        DispatchQueue.main.async {
          // Ask up front rather than failing on the first wake.
          let screen = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
          log("permissions: speech=\(status.rawValue) mic=\(mic) screen=\(screen)")
          self.model.applyListening()
        }
      }
    }
  }

  // Opening the app again (Spotlight, Finder) shows Settings: on a crowded menu bar the
  // icon can be hidden behind the notch.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showSettings()
    return false
  }

  @objc private func showSettings() {
    NSApp.activate()
    settingsWindow.center()
    settingsWindow.makeKeyAndOrderFront(nil)
  }

  private func refreshIcon() {
    let name = model.running ? "waveform" : "waveform.slash"
    statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Hey Claude")
    statusItem.button?.appearsDisabled = !model.running
  }

  private func installDefaultConfig() {
    guard !FileManager.default.fileExists(atPath: configURL.path),
      let template = Bundle.main.url(forResource: "config", withExtension: "env")
    else { return }
    try? FileManager.default.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: template, to: configURL)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
