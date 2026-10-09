// Dictate: tap right Command or right Option (or press F13 / PC Print Screen) to start
// recording, again to transcribe on marvin's Whisper server, paste the text into the
// focused app and press Return.
import AppKit
import AVFoundation
import Carbon.HIToolbox

let server = URL(string: "http://100.100.184.6:8765/transcribe")!
let tokenPath = NSString(string: "~/.config/dictate/token").expandingTildeInPath
let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-clip.wav")
let logPath = NSString(string: "~/Library/Logs/Dictate.log").expandingTildeInPath

func log(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

// Small floating status pill that never takes focus.
final class HUD {
    let panel: NSPanel
    let label = NSTextField(labelWithString: "")
    var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        panel.contentView = box
    }

    func show(_ text: String, for seconds: Double? = nil) {
        hideWork?.cancel()
        label.stringValue = text
        let size = NSSize(width: label.intrinsicContentSize.width + 40, height: 40)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 24,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hud = HUD()
    var recorder: AVAudioRecorder?
    var busy = false
    var hotKeyRef: EventHotKeyRef?
    var eventTap: CFMachPort?
    // Modifier key currently held alone (keycode, when pressed); a quick release = tap.
    var tapCandidate: (keycode: Int64, since: Date)?
    var secureInputSince: Date?
    var warnedSecureInput = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        log("started; accessibility=\(AXIsProcessTrusted()) inputMonitoring=\(CGPreflightListenEventAccess()) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        registerHotKey()
        installModifierTap()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.checkSecureInput() }
    }

    // F13 = Print Screen on PC-layout keyboards (Carbon hotkeys need no permission).
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_F13), 0,
                            EventHotKeyID(signature: OSType(0x4454_4354), id: 1), // 'DTCT'
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // A lone tap of right Command or right Option toggles too. Modifier events get
    // through even while another app holds Secure Keyboard Entry, so this is the most
    // dependable trigger. Needs Input Monitoring; retries until it has been granted.
    func installModifierTap() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: { _, type, event, _ in
            (NSApp.delegate as? AppDelegate)?.handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let eventTap else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.installModifierTap() }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, eventTap, 0), .commonModes)
    }

    static let tapKeys: [Int64: CGEventFlags] = [
        Int64(kVK_RightCommand): .maskCommand,
        Int64(kVK_RightOption): .maskAlternate,
    ]

    func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        case .flagsChanged:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            guard let flag = Self.tapKeys[kc] else { tapCandidate = nil; return }
            if event.flags.contains(flag) {
                tapCandidate = (kc, Date())
            } else if let c = tapCandidate, c.keycode == kc {
                tapCandidate = nil
                if Date().timeIntervalSince(c.since) < 0.4 { toggle() }
            }
        default:
            tapCandidate = nil // another key or click: the modifier was used as a modifier
        }
    }

    // Secure Keyboard Entry (a terminal at a password prompt, or stuck on) hides key
    // presses from every other app, which silently kills the F13 hotkey. Say so.
    func checkSecureInput() {
        guard IsSecureEventInputEnabled() else {
            secureInputSince = nil
            warnedSecureInput = false
            return
        }
        if secureInputSince == nil { secureInputSince = Date() }
        if !warnedSecureInput, Date().timeIntervalSince(secureInputSince!) > 15 {
            warnedSecureInput = true
            log("secure keyboard entry has been on for 15s; F13 hotkey blocked")
            hud.show("Secure Keyboard Entry is on in another app: Print Screen blocked, right ⌘/⌥ taps still work", for: 6)
        }
    }

    func toggle() {
        if busy { return }
        if let recorder, recorder.isRecording {
            recorder.stop()
            self.recorder = nil
            transcribe()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            hud.show("Allow microphone access for Dictate in System Settings", for: 5)
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: clipURL, settings: settings)
            guard r.record(forDuration: 300) else { throw NSError(domain: "Dictate", code: 1) }
            recorder = r
            hud.show("Recording… tap right ⌘ to stop")
        } catch {
            hud.show("Could not start recording", for: 4)
        }
    }

    func transcribe() {
        guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8),
              let audio = try? Data(contentsOf: clipURL) else {
            hud.show("Missing token or recording", for: 4)
            return
        }
        try? FileManager.default.removeItem(at: clipURL)
        busy = true
        hud.show("Transcribing…")
        var req = URLRequest(url: server, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
                     forHTTPHeaderField: "Authorization")
        URLSession.shared.uploadTask(with: req, from: audio) { data, resp, error in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if !ok { log("transcribe failed: status=\((resp as? HTTPURLResponse)?.statusCode ?? 0) error=\(error?.localizedDescription ?? "-")") }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self.busy = false
                if !ok {
                    self.hud.show("Transcription failed (is marvin reachable?)", for: 5)
                } else if text.isEmpty {
                    self.hud.show("No speech detected", for: 2)
                } else {
                    self.paste(text)
                }
            }
        }.resume()
    }

    // Paste via the clipboard (restored afterwards), then press Return to send.
    func paste(_ text: String) {
        guard AXIsProcessTrusted() else {
            hud.show("Allow Accessibility access for Dictate in System Settings", for: 5)
            return
        }
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        key(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.key(CGKeyCode(kVK_Return), flags: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            if let old { pb.setString(old, forType: .string) }
            self.hud.hide()
        }
    }

    func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
