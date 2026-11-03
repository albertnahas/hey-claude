// Hey Claude: listens on-device for a wake phrase ("Hey Claude" by default) and runs the
// bundled hey-claude.sh (screenshot → Claude Code in tmux → terminal window attached to it).

import AVFoundation
import AppKit
import ServiceManagement
import Speech
import SwiftUI

private let home = FileManager.default.homeDirectoryForCurrentUser
private let logURL = home.appendingPathComponent("Library/Logs/HeyClaude.log")
private let configURL = home.appendingPathComponent(".config/hey-claude/config.env")

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

// MARK: - Wake-phrase listener

final class WakeListener {
  /// Phrases that wake the app, matched as whole words, case-insensitively.
  var phrases: [String] = [] {
    didSet {
      let alternatives = phrases.map { phrase in
        phrase.split(whereSeparator: \.isWhitespace)
          .map { NSRegularExpression.escapedPattern(for: String($0)) }
          .joined(separator: #"\W+"#)
      }
      wakePattern = try! NSRegularExpression(
        pattern: #"\b("# + alternatives.joined(separator: "|") + #")\b"#, options: .caseInsensitive)
      if engine.isRunning { beginTask() }
    }
  }

  // The system language when the recognizer supports it, otherwise US English.
  private let recognizer =
    SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var rotation: Timer?
  private var configObserver: NSObjectProtocol?
  private var wakePattern: NSRegularExpression?
  /// Set from the wake phrase until the speaker pauses: what they said after it.
  private var question: String?
  private var pause: Timer?
  private let onHeard: () -> Void
  private let onWake: (String) -> Void

  /// `onHeard`: the wake phrase was recognised. `onWake`: the speaker paused, with the
  /// question that followed the phrase (empty when there was none).
  init(onHeard: @escaping () -> Void, onWake: @escaping (String) -> Void) {
    self.onHeard = onHeard
    self.onWake = onWake
  }

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
    // A new mic or headset (or a call taking the input) stops the engine and changes the input
    // format. Restart with a fresh tap, or the app keeps transcribing silence while looking alive.
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      log("audio input changed, restarting")
      self.stop()
      do { try self.start() } catch { log("restart failed: \(error)") }
    }
    beginTask()
    log("listening for \(phrases) in \(recognizer.locale.identifier) (on-device: \(recognizer.supportsOnDeviceRecognition))")
  }

  func stop() {
    configObserver.map(NotificationCenter.default.removeObserver)
    configObserver = nil
    rotation?.invalidate()
    pause?.invalidate()
    question = nil
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

  // One recognition task at a time, rotated every 50 s so transcripts stay short,
  // and after every wake so the same utterance never fires twice.
  private func beginTask() {
    if question != nil { return finish() }  // never cut a question off mid-sentence
    task?.cancel()
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    req.shouldReportPartialResults = true
    req.contextualStrings = phrases
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
      let match = wakePattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let end = Range(match.range, in: text)?.upperBound
    {
      if question == nil { onHeard() }
      // "Hey Claude, why…?" → "why…?": drop the separator, keep the question's own punctuation.
      question = String(
        text[end...].drop { $0.isWhitespace || $0.isPunctuation }
      ).trimmingCharacters(in: .whitespaces)
      // Each new partial result means they are still talking; fire after a 2 s pause.
      pause?.invalidate()
      pause = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
        self?.finish()
      }
      if result?.isFinal == true { finish() }
    } else if question != nil, result?.isFinal == true || error != nil {
      finish()
    } else if result?.isFinal == true || error != nil {
      // The recognizer ends a task after long silence; restart after a beat to avoid a hot loop.
      swapRequest(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self, self.request == nil, self.engine.isRunning else { return }
        self.beginTask()
      }
    }
  }

  private func finish() {
    guard let question else { return }
    pause?.invalidate()
    self.question = nil
    log("wake (question: \(question.split(separator: " ").count) words)")
    beginTask()
    onWake(question)
  }
}

// MARK: - State

final class AppModel: ObservableObject {
  static let defaultPhrases = "Hey Claude, Hello Claude"

  @Published var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
    didSet {
      UserDefaults.standard.set(enabled, forKey: "enabled")
      applyListening()
    }
  }
  /// Comma-separated wake phrases, as typed in Settings.
  @Published var wakePhrases = UserDefaults.standard.string(forKey: "wakePhrases") ?? defaultPhrases {
    didSet {
      UserDefaults.standard.set(wakePhrases, forKey: "wakePhrases")
      listener.phrases = Self.parse(wakePhrases)
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
  /// Between hearing the wake phrase and the speaker's pause.
  private(set) var hearing = false
  var onChange: () -> Void = {}

  private lazy var listener: WakeListener = {
    let listener = WakeListener(
      onHeard: { [weak self] in
        self?.hearing = true
        self?.onChange()
      },
      onWake: { [weak self] question in
        self?.hearing = false
        self?.onChange()
        self?.wake(question)
      })
    listener.phrases = Self.parse(wakePhrases)
    return listener
  }()
  private var busy = false

  private static func parse(_ text: String) -> [String] {
    let phrases = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return phrases.isEmpty ? parse(defaultPhrases) : phrases
  }

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

  private func wake(_ question: String) {
    guard !busy else { return }
    busy = true
    let process = Process()
    process.executableURL = Bundle.main.url(forResource: "hey-claude", withExtension: "sh")
    process.arguments = [String(NSScreen.screens.count), question]
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
  @State private var phrasesDraft = ""

  var body: some View {
    Form {
      Toggle("Listen for the wake phrase", isOn: $model.enabled)
      TextField("Wake phrases", text: $phrasesDraft, prompt: Text(AppModel.defaultPhrases))
        .onSubmit { model.wakePhrases = phrasesDraft }
        .help("Separate phrases with commas. Press Return to apply.")
      Toggle("Open at login", isOn: $model.openAtLogin)
      HStack {
        Button("Edit session settings…", action: model.openConfig)
        Button("Show log", action: model.showLog)
      }
    }
    .padding(20)
    .frame(width: 420)
    .onAppear { phrasesDraft = model.wakePhrases }
    .onDisappear { model.wakePhrases = phrasesDraft }
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
    let name = model.hearing ? "ear" : model.running ? "waveform" : "waveform.slash"
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
