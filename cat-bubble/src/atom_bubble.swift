// AtomBubble: a desktop pet overlay that shows the installed Codex "Atom" pet
// on a transparent, borderless, always-on-top window. It occasionally pops a
// short speech bubble in Atom's voice (offline phrase bank by default; can call
// an OpenAI-compatible API to generate fresh lines on demand) and is the same
// surface where Codex approval Allow/Deny bubbles are surfaced in the future.
//
// Build:  swiftc -O -framework AppKit -o atom-bubble atom_bubble.swift
// Run:    ./atom-bubble [--phrases path] [--live-model] [--snapshot out.png]
//                   [--demo-approval] [--interval-min 18] [--interval-max 50]

import AppKit
import Carbon
import Foundation

// MARK: - Phrase bank loader -----------------------------------------------

struct PhraseBank {
    let persona: String
    let rules: [String]
    var phrases: [String]

    static func load(from url: URL) -> PhraseBank? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let persona = (obj["persona"] as? String) ?? ""
        let rules = (obj["voice_rules"] as? [String]) ?? []
        let phrases = (obj["phrases"] as? [String]) ?? []
        return PhraseBank(persona: persona, rules: rules, phrases: phrases)
    }

    static func sample(_ phrases: [String]) -> String {
        guard !phrases.isEmpty else { return "喵。" }
        return phrases[Int.random(in: 0..<phrases.count)]
    }
}

// MARK: - Optional live generation via an OpenAI-compatible chat API -------

enum LiveGenerator {
    static func generate(apiKey: String, baseURL: String, model: String,
                         persona: String, rules: [String], count: Int,
                         completion: @escaping ([String]) -> Void) {
        let systemPrompt = """
        You are \(persona)
        Hard rules:
        \(rules.map { "- \($0)" }.joined(separator: "\n"))
        Return a JSON array of \(count) short lines, no other text.
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": systemPrompt],
                         ["role": "user",   "content": "Give me \(count) lines now."]],
            "max_tokens": 400,
            "temperature": 0.9,
        ]
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            completion([]); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard let data = data, err == nil,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let msg = first["message"] as? [String: Any],
                  let content = msg["content"] as? String
            else { completion([]); return }
            // Strip code fences if present, then JSON-parse the array.
            var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("```") {
                if let r = text.range(of: "\n") { text = String(text[r.upperBound...]) }
                if let r = text.range(of: "```", options: .backwards) { text = String(text[..<r.lowerBound]) }
            }
            if let arr = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String] {
                completion(arr)
            } else if let lines = text.components(separatedBy: "\n") as [String]? {
                completion(lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            } else {
                completion([])
            }
        }.resume()
    }
}


// MARK: - Codex app-server bridge ------------------------------------------

final class CodexBridge {
    private var process: Process?
    private var inputPipe: Pipe?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "atom.codex.bridge")
    private var nextId = 1
    private var callbacks: [Int: (Any?) -> Void] = [:]
    private var threadId: String?
    private var busy = false

    var onReady: ((String) -> Void)?
    var onApproval: ((Int, [String: Any]) -> Void)?
    var onAgentMessage: ((String) -> Void)?
    var onTurnCompleted: (() -> Void)?
    var onError: ((String) -> Void)?

    var isBusy: Bool { busy }

    func start(cwd: String, approvalPolicy: String, sandbox: String) {
        let bin = ProcessInfo.processInfo.environment["CODEX_BIN"]
            ?? "/Users/yanyuting/.mcc/.npm-global/bin/codex"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["app-server", "--listen", "stdio://"]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let input = Pipe()
        let output = Pipe()
        let err = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = err
        inputPipe = input
        process = proc

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onError?("codex app-server 退出了") }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async { self.onError?("启动 codex 失败: \(error.localizedDescription)") }
            return
        }

        sendRequest(method: "initialize",
                    params: ["clientInfo": ["name": "atom-buddy", "title": "Atom Buddy", "version": "0.1.0"],
                             "capabilities": ["experimentalApi": true]]) { [weak self] _ in
            guard let self else { return }
            self.sendNotification(method: "initialized")
            self.sendRequest(method: "thread/start",
                             params: ["cwd": cwd, "approvalPolicy": approvalPolicy,
                                      "sandbox": sandbox, "ephemeral": true]) { result in
                guard let obj = result as? [String: Any],
                      let thread = obj["thread"] as? [String: Any],
                      let tid = thread["id"] as? String else {
                    DispatchQueue.main.async { self.onError?("thread/start 失败") }
                    return
                }
                self.threadId = tid
                DispatchQueue.main.async { self.onReady?(tid) }
            }
        }
    }

    func startTurn(prompt: String) {
        guard let tid = threadId else {
            DispatchQueue.main.async { self.onError?("还没有 Codex 会话") }
            return
        }
        busy = true
        sendRequest(method: "turn/start",
                    params: ["threadId": tid,
                             "input": [["type": "text", "text": prompt]],
                             "approvalPolicy": "on-request"]) { [weak self] result in
            guard let self else { return }
            if let obj = result as? [String: Any], obj["error"] != nil {
                DispatchQueue.main.async { self.onError?("turn/start 失败") }
            }
        }
    }

    func respondApproval(id: Int, decision: String) {
        sendResponse(id: id, result: ["decision": decision])
    }

    private func sendNotification(method: String, params: [String: Any] = [:]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func sendRequest(method: String, params: [String: Any],
                             completion: @escaping (Any?) -> Void) {
        let id = nextId
        nextId += 1
        callbacks[id] = completion
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func sendResponse(id: Int, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ obj: [String: Any]) {
        guard let input = inputPipe else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write("\n".data(using: .utf8)!)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        var lines: [Data] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<idx)
            lines.append(line)
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ msg: [String: Any]) {
        if let id = msg["id"] as? Int, msg["method"] == nil {
            if let cb = callbacks.removeValue(forKey: id) { cb(msg["result"]) }
            return
        }
        guard let method = msg["method"] as? String else { return }
        let params = (msg["params"] as? [String: Any]) ?? [:]
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval":
            if let id = msg["id"] as? Int {
                DispatchQueue.main.async { self.onApproval?(id, params) }
            }
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               let type = item["type"] as? String,
               type == "agentMessage",
               let text = item["text"] as? String {
                DispatchQueue.main.async { self.onAgentMessage?(text) }
            }
        case "turn/completed":
            busy = false
            DispatchQueue.main.async { self.onTurnCompleted?() }
        case "turn/started":
            busy = true
        default:
            break
        }
    }
}

// MARK: - Speech bubble view -----------------------------------------------

final class SpeechBubbleView: NSView {
    private let textField = NSTextField(labelWithString: "")
    private let tailLayer = CAShapeLayer()
    private var bubbleLayer = CAShapeLayer()
    private var currentText = ""
    private var maxWidth: CGFloat = 360
    private var scale: CGFloat = 1

    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = .clear
        bubbleLayer.fillColor = NSColor(srgbRed: 0.96, green: 0.89, blue: 0.71, alpha: 1).cgColor
        bubbleLayer.shadowColor = NSColor(srgbRed: 0.35, green: 0.22, blue: 0.08, alpha: 1).cgColor
        bubbleLayer.shadowOpacity = 0.18
        bubbleLayer.shadowOffset = CGSize(width: 0, height: -2)
        bubbleLayer.shadowRadius = 6
        layer?.addSublayer(bubbleLayer)

        tailLayer.fillColor = NSColor(srgbRed: 0.96, green: 0.89, blue: 0.71, alpha: 1).cgColor
        tailLayer.shadowColor = NSColor.black.cgColor
        tailLayer.shadowOpacity = 0.18
        tailLayer.shadowOffset = CGSize(width: 0, height: -1)
        tailLayer.shadowRadius = 3
        layer?.addSublayer(tailLayer)

        textField.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        textField.textColor = NSColor(srgbRed: 0.30, green: 0.20, blue: 0.09, alpha: 1)
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byCharWrapping
        textField.alignment = .left
        addSubview(textField)

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick)))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleClick() { onClick?() }

    func setText(_ text: String, maxWidth: CGFloat) {
        currentText = text
        self.maxWidth = maxWidth
        layoutContent()
    }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
        layoutContent()
    }

    private func layoutContent() {
        guard !currentText.isEmpty else { return }
        textField.stringValue = currentText
        let s = scale
        textField.font = NSFont.systemFont(ofSize: 14 * s, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: textField.font!]
        let natural = (currentText as NSString).size(withAttributes: attrs)
        let width = min(maxWidth * s, max(180 * s, ceil(natural.width) + 44 * s))
        let height = ceil(natural.height) + 26 * s
        textField.frame = NSRect(x: 16 * s, y: 13 * s, width: width - 32 * s, height: height - 26 * s)
        setFrameSize(NSSize(width: width, height: height))
        updateShape()
    }

    override func layout() { super.layout(); updateShape() }

    private func updateShape() {
        let r = bounds
        let radius: CGFloat = 14 * scale
        let bubble = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        bubbleLayer.path = bubble.cgPath

        // tail points down to the lower-left, toward the pet's head
        let tailPath = NSBezierPath()
        let tx = r.minX + 36 * scale
        tailPath.move(to: NSPoint(x: tx, y: 0))
        tailPath.line(to: NSPoint(x: tx + 18 * scale, y: 0))
        tailPath.line(to: NSPoint(x: tx + 4 * scale, y: -12 * scale))
        tailPath.close()
        tailLayer.path = tailPath.cgPath
        tailLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 12)
    }
}

// MARK: - Approval bubble (Allow / Deny) -----------------------------------

final class ApprovalBubbleView: NSView {
    private let titleLabel = NSTextField(labelWithString: "需要授权")
    private let cmdLabel = NSTextField(labelWithString: "")
    private let allowBtn = NSButton(title: "允许", target: nil, action: nil)
    private let denyBtn  = NSButton(title: "拒绝", target: nil, action: nil)
    private let bubbleLayer = CAShapeLayer()
    private var cmd = ""
    private var scale: CGFloat = 1

    var onAllow: (() -> Void)?
    var onDeny: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer(); layer?.backgroundColor = .clear
        bubbleLayer.fillColor = NSColor(srgbRed: 0.96, green: 0.89, blue: 0.71, alpha: 1).cgColor
        bubbleLayer.shadowColor = NSColor(srgbRed: 0.35, green: 0.22, blue: 0.08, alpha: 1).cgColor
        bubbleLayer.shadowOpacity = 0.22
        bubbleLayer.shadowOffset = CGSize(width: 0, height: -2)
        bubbleLayer.shadowRadius = 8
        layer?.addSublayer(bubbleLayer)

        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.textColor = NSColor(srgbRed: 0.30, green: 0.20, blue: 0.09, alpha: 1)
        addSubview(titleLabel)

        cmdLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cmdLabel.textColor = NSColor(srgbRed: 0.42, green: 0.29, blue: 0.13, alpha: 1)
        cmdLabel.maximumNumberOfLines = 2
        cmdLabel.lineBreakMode = .byWordWrapping
        addSubview(cmdLabel)

        allowBtn.bezelStyle = .rounded
        allowBtn.contentTintColor = NSColor.systemGreen
        allowBtn.target = self
        allowBtn.action = #selector(allowTapped)
        addSubview(allowBtn)

        denyBtn.bezelStyle = .rounded
        denyBtn.contentTintColor = NSColor.systemRed
        denyBtn.target = self
        denyBtn.action = #selector(denyTapped)
        addSubview(denyBtn)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func allowTapped() { onAllow?() }
    @objc private func denyTapped() { onDeny?() }

    func setCommand(_ cmd: String) {
        self.cmd = cmd
        layoutContent()
    }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
        layoutContent()
    }

    private func layoutContent() {
        let s = scale
        titleLabel.stringValue = "需要授权"
        cmdLabel.stringValue = cmd
        cmdLabel.toolTip = cmd
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14 * s)
        cmdLabel.font = NSFont.monospacedSystemFont(ofSize: 11 * s, weight: .regular)
        let w: CGFloat = 300 * s
        let buttonH: CGFloat = 28 * s
        let pad: CGFloat = 10 * s
        let titleAttr: [NSAttributedString.Key: Any] = [.font: titleLabel.font!]
        let cmdAttr: [NSAttributedString.Key: Any] = [.font: cmdLabel.font!]
        let titleH = ceil((titleLabel.stringValue as NSString).boundingRect(
            with: CGSize(width: w - 24 * s, height: 60 * s), options: [.usesLineFragmentOrigin], attributes: titleAttr).height)
        let cmdH = min(30, ceil((cmd as NSString).boundingRect(
            with: CGSize(width: w - 24 * s, height: 200 * s), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: cmdAttr).height))
        let h: CGFloat = pad + titleH + 4 + cmdH + 8 + buttonH + pad
        setFrameSize(NSSize(width: w, height: h))

        titleLabel.frame = NSRect(x: 12 * s, y: h - pad - titleH, width: w - 24 * s, height: titleH)
        cmdLabel.frame   = NSRect(x: 12 * s, y: h - pad - titleH - 4 * s - cmdH, width: w - 24 * s, height: cmdH)
        let btnW: CGFloat = 64 * s
        let rowW = btnW * 2 + 8 * s
        allowBtn.frame   = NSRect(x: (w - rowW) / 2, y: pad, width: btnW, height: buttonH)
        denyBtn.frame    = NSRect(x: (w - rowW) / 2 + btnW + 8, y: pad, width: btnW, height: buttonH)
        bubbleLayer.path = NSBezierPath(roundedRect: bounds, xRadius: 14 * s, yRadius: 14 * s).cgPath
    }

    override func layout() {
        super.layout()
        bubbleLayer.path = NSBezierPath(roundedRect: bounds, xRadius: 14 * scale, yRadius: 14 * scale).cgPath
    }
}

// MARK: - Pet drag container ------------------------------------------------

final class PetView: NSImageView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((NSPoint) -> Void)?
    var onHoverExit: (() -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var start: NSPoint = .zero
    private var last: NSPoint = .zero
    private var dragged = false
    private var singleTimer: Timer?

    override func mouseDown(with event: NSEvent) {
        AppLog.log("pet mouseDown fired")
        start = event.locationInWindow
        last = start
        dragged = false
        if event.clickCount == 2 {
            singleTimer?.invalidate()
            onDoubleClick?()
        } else {
            singleTimer?.invalidate()
            singleTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { [weak self] _ in
                self?.onSingleClick?()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        let delta = NSPoint(x: p.x - last.x, y: p.y - last.y)
        last = p
        if abs(p.x - start.x) + abs(p.y - start.y) > 4 { dragged = true }
        if dragged {
            singleTimer?.invalidate()
            onDragMove?(delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?() }
        dragged = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverExit?()
    }
}

final class PetDragView: NSView {
    var onDrag: ((NSPoint) -> Void)?
    private var start: NSPoint = .zero
    private var last: NSPoint = .zero
    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        last = start
    }
    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        let delta = NSPoint(x: p.x - last.x, y: p.y - last.y)
        last = p
        onDrag?(delta)
    }
}

// MARK: - Debug log ---------------------------------------------------------

enum AppLog {
    static let dir = (NSHomeDirectory() as NSString).appendingPathComponent(
        "Documents/Codex/2026-08-16/atom-hatch-pet-v2-users-yanyuting/work/atom-sidecar/logs")
    static let path = dir + "/app.log"

    static func log(_ text: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + text + "\n"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Global hotkeys (Carbon, no accessibility permission needed) ------

final class HotkeyManager {
    static let shared = HotkeyManager()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private init() {}

    private let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
        var hotkeyID = EventHotKeyID()
        GetEventParameter(event,
                          EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID),
                          nil,
                          MemoryLayout<EventHotKeyID>.size,
                          nil,
                          &hotkeyID)
        let id = hotkeyID.id
        AppLog.log("hotkey event fired id=\(id)")
        DispatchQueue.main.async { HotkeyManager.shared.handlers[id]?() }
        return noErr
    }

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        handlers[id] = handler
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, nil)
        }
        var hotkeyID = EventHotKeyID(signature: OSType(0x41544F4D), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotkeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            print("hotkey registered: id=\(id) keyCode=\(keyCode) modifiers=\(modifiers)")
        } else {
            print("hotkey registration failed: id=\(id) status=\(status)")
        }
    }
}

// MARK: - Main controller ---------------------------------------------------

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var petView: PetView!
    private var petDrag: PetDragView!
    private var bubbleView: SpeechBubbleView!
    private var approvalView: ApprovalBubbleView?
    private var idleFrames: [NSImage] = []
    private var jumpFrames: [NSImage] = []
    private var waveFrames: [NSImage] = []
    private var runningRightFrames: [NSImage] = []
    private var runningLeftFrames: [NSImage] = []
    private var lookFrames: [NSImage] = []
    private var frameTimer: Timer?
    private var isHovering = false
    private var lastCursor: NSPoint = .zero
    private var lastRunningDirection: CGFloat = 1
    private var petScale: CGFloat = 1
    private enum PetMode { case idle, lookUp, hover, jump, wave, running }
    private var mode: PetMode = .idle
    private var bubbleTimer: Timer?
    private var fadeTimer: Timer?
    private var frameIdx = 0
    private var bank: PhraseBank!
    private var intervalMin: TimeInterval = 540
    private var intervalMax: TimeInterval = 660
    private var codex: CodexBridge?
    private var pendingApprovalId: Int?
    private var statusItem: NSStatusItem?
    private var globalKeyMonitor: Any?
    private var visibilityItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        let exeDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let assetsDir = argValue("--assets-dir", default: exeDir + "/assets")
        let phrasesPath = URL(fileURLWithPath: argValue("--phrases",
            default: exeDir + "/phrases.json"))
        let snapshotPath = argValue("--snapshot", default: "")
        let demoApproval = args.contains("--demo-approval")
        let liveMode = args.contains("--live-model")
        let forcedText = argValueOptional("--text")
        let codexMode = args.contains("--codex")
        let codexCwd = argValue("--cwd", default: FileManager.default.currentDirectoryPath)
        let approvalPolicy = argValue("--approval-policy", default: "on-request")
        let sandbox = argValue("--sandbox", default: "read-only")
        if let v = argValueOptional("--interval-min"), let n = Double(v) { intervalMin = n }
        if let v = argValueOptional("--interval-max"), let n = Double(v) { intervalMax = n }

        bank = PhraseBank.load(from: phrasesPath) ?? PhraseBank(persona: "Atom", rules: [], phrases: ["喵。"])
        loadFrames(assetsDir: assetsDir)

        NSApp.setActivationPolicy(.accessory)

        let winSize = NSSize(width: 420, height: 400)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: winSize),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.delegate = self
        window.acceptsMouseMovedEvents = true

        let content = NSView(frame: NSRect(origin: .zero, size: winSize))
        content.wantsLayer = true
        content.layer?.backgroundColor = .clear
        window.contentView = content

        // Drag layer covers the bubble area (not the pet) so the pet itself can be clicked without moving the window.
        petDrag = PetDragView(frame: NSRect(x: 0, y: 0, width: winSize.width, height: winSize.height))
        petDrag.wantsLayer = true
        petDrag.layer?.backgroundColor = .clear
        petDrag.onDrag = { [weak self] delta in self?.moveWindow(by: delta) }
        content.addSubview(petDrag)

        petView = PetView(frame: NSRect(x: (winSize.width - 192) / 2,
                                            y: 16, width: 192, height: 208))
        petView.onSingleClick = { [weak self] in self?.forceNextBubble() }
        petView.onDoubleClick = { [weak self] in self?.playWave() }
        petView.onHover = { [weak self] point in self?.handleHover(point) }
        petView.onHoverExit = { [weak self] in self?.exitHover() }
        petView.onDragMove = { [weak self] delta in
            self?.moveWindow(by: delta)
            self?.setRunning(direction: delta.x)
        }
        petView.onDragEnd = { [weak self] in self?.stopRunning() }
        petView.imageScaling = .scaleProportionallyUpOrDown
        petView.image = idleFrames.first
        petView.wantsLayer = true
        petDrag.addSubview(petView)

        bubbleView = SpeechBubbleView(frame: .zero)
        bubbleView.alphaValue = 0
        bubbleView.onClick = { [weak self] in self?.forceNextBubble() }
        petDrag.addSubview(bubbleView)

        positionBubble(forSpeech: true, text: nil)

        window.setFrameOrigin(NSPoint(
            x: NSScreen.main?.frame.midX ?? 500,
            y: 140))
        window.orderFrontRegardless()
        AppLog.log("window visible=\(window.isVisible) frame=\(window.frame) level=\(window.level.rawValue) screen=\(String(describing: NSScreen.main?.frame))")

        installContextMenu()
        registerHotkeys()
        setupStatusItem()

        startIdleLoop()
        if codexMode {
            setupCodex(cwd: codexCwd, approvalPolicy: approvalPolicy, sandbox: sandbox)
        } else {
            scheduleNextBubble()
        }

        if demoApproval { showApprovalBubble(command: "rm -rf /tmp/example && echo \"would do work\"") }
        if liveMode { triggerLiveGeneration() }
        if args.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.forceNextBubble()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.ctxDemoApproval()
            }
        }

        if !snapshotPath.isEmpty {
            if let forced = forcedText {
                showBubble(text: forced)
            } else if !demoApproval {
                forceNextBubble()
            }
            if demoApproval { showApprovalBubble(command: argValueOptional("--approval-cmd") ?? "rm -rf /tmp/atom-demo && echo allow_demo") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.writeSnapshot(to: snapshotPath)
                NSApp.terminate(nil)
            }
        }
    }

    private func argValue(_ key: String, default def: String) -> String {
        argValueOptional(key) ?? def
    }
    private func argValueOptional(_ key: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private func loadFrames(assetsDir: String) {
        let root = URL(fileURLWithPath: assetsDir)
        idleFrames = loadSequence(root.appendingPathComponent("idle"), count: 6)
        jumpFrames = loadSequence(root.appendingPathComponent("jumping"), count: 5)
        waveFrames = loadSequence(root.appendingPathComponent("waving"), count: 4)
        runningRightFrames = loadSequence(root.appendingPathComponent("running-right"), count: 8)
        runningLeftFrames = loadSequence(root.appendingPathComponent("running-left"), count: 8)
        lookFrames = loadSequence(root.appendingPathComponent("look"), count: 16, prefix: "look-")
        if lookFrames.isEmpty {
            lookFrames = loadSequence(root, count: 1, prefix: "look-up-")
        }
        if idleFrames.isEmpty {
            let placeholder = NSImage(size: NSSize(width: 192, height: 208))
            placeholder.lockFocus()
            NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: 192, height: 208).fill()
            placeholder.unlockFocus()
            idleFrames = [placeholder]
        }
    }

    private func loadSequence(_ dir: URL, count: Int, prefix: String = "frame-") -> [NSImage] {
        var imgs: [NSImage] = []
        for i in 0..<count {
            if let im = NSImage(contentsOf: dir.appendingPathComponent("\(prefix)\(i).png")) {
                imgs.append(im)
            }
        }
        return imgs
    }

    private func setLookingUp(_ flag: Bool) {
        if flag {
            mode = .lookUp
            frameTimer?.invalidate()
            if let up = lookFrames.first { petView.image = up }
        } else if mode == .lookUp {
            if isHovering { handleHover(lastCursor) } else { startIdleLoop() }
        }
    }

    private func startIdleLoop() {
        mode = .idle
        frameTimer?.invalidate()
        guard !idleFrames.isEmpty else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, !self.idleFrames.isEmpty else { return }
            self.frameIdx = (self.frameIdx + 1) % self.idleFrames.count
            self.petView.image = self.idleFrames[self.frameIdx]
        }
    }

    private func handleHover(_ point: NSPoint) {
        isHovering = true
        lastCursor = point
        guard mode == .idle || mode == .hover else { return }
        if mode != .hover {
            mode = .hover
            frameTimer?.invalidate()
        }
        if !lookFrames.isEmpty { petView.image = lookFrames[lookIndex(for: point)] }
    }

    private func exitHover() {
        isHovering = false
        if mode == .hover { startIdleLoop() }
    }

    private func lookIndex(for point: NSPoint) -> Int {
        let center = NSPoint(x: petView.frame.midX, y: petView.frame.midY)
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        var deg = atan2(dx, dy) * 180.0 / Double.pi
        if deg < 0 { deg += 360 }
        return Int((deg / 22.5).rounded()) % 16
    }

    private func playJump() {
        AppLog.log("playJump")
        playOneShot(jumpFrames, petMode: .jump, interval: 0.16)
    }

    private func playWave() {
        AppLog.log("playWave")
        playOneShot(waveFrames, petMode: .wave, interval: 0.2)
    }

    private func playOneShot(_ images: [NSImage], petMode: PetMode, interval: TimeInterval) {
        frameTimer?.invalidate()
        mode = petMode
        guard !images.isEmpty else { finishOneShot(); return }
        var i = 0
        petView.image = images[0]
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            i += 1
            guard let self else { return }
            if i < images.count {
                self.petView.image = images[i]
            } else {
                self.frameTimer?.invalidate()
                self.finishOneShot()
            }
        }
    }

    private func finishOneShot() {
        if isHovering { handleHover(lastCursor) } else { startIdleLoop() }
    }

    private func setRunning(direction: CGFloat) {
        let imgs = direction >= 0 ? runningRightFrames : runningLeftFrames
        if mode != .running || (lastRunningDirection >= 0) != (direction >= 0) {
            lastRunningDirection = direction
            mode = .running
            frameTimer?.invalidate()
            guard !imgs.isEmpty else { return }
            var i = 0
            petView.image = imgs[0]
            frameTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self else { return }
                i = (i + 1) % imgs.count
                self.petView.image = imgs[i]
            }
        }
    }

    private func stopRunning() {
        guard mode == .running else { return }
        if isHovering { handleHover(lastCursor) } else { startIdleLoop() }
    }

    private func moveWindow(by delta: NSPoint) {
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
    }

    private func scheduleNextBubble() {
        let delay = TimeInterval.random(in: intervalMin...intervalMax)
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.showNextSpeechBubble()
            self?.scheduleNextBubble()
        }
    }

    private func forceNextBubble() {
        AppLog.log("forceNextBubble called")
        showNextSpeechBubble()
    }

    private func showNextSpeechBubble() {
        let phrase = PhraseBank.sample(bank.phrases)
        showBubble(text: phrase)
    }

    private func triggerLiveGeneration() {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["OPENAI_API_KEY"] else { return }
        let baseURL = env["OPENAI_BASE_URL"] ?? "https://api.openai.com"
        let model   = env["OPENAI_MODEL"]   ?? "gpt-5.5"
        LiveGenerator.generate(apiKey: key, baseURL: baseURL, model: model,
                               persona: bank.persona, rules: bank.rules, count: 12) { lines in
            DispatchQueue.main.async {
                if !lines.isEmpty { self.bank.phrases = lines }
            }
        }
    }

    private func showBubble(text: String) {
        AppLog.log("showBubble: " + text)
        bubbleView.setText(text, maxWidth: 360)
        positionBubble(forSpeech: true, text: text)
        bubbleView.animator().alphaValue = 1
        setLookingUp(true)
        // Hide after a delay, longer for longer phrases.
        let duration: TimeInterval = max(5, min(10, Double(text.count) * 0.35))
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self?.bubbleView.animator().alphaValue = 0
            } completionHandler: {
                self?.setLookingUp(false)
            }
        }
    }

    private func positionBubble(forSpeech: Bool, text: String?) {
        let w: CGFloat = bubbleView.frame.width > 0 ? bubbleView.frame.width : 220
        let h: CGFloat = bubbleView.frame.height
        let centerX = petView.frame.midX
        let bottomY = petView.frame.maxY + 10
        bubbleView.frame.origin = NSPoint(
            x: min(max(centerX - w / 2, 8), max(8, petDrag.bounds.width - w - 8)),
            y: min(max(bottomY, 8), max(8, petDrag.bounds.height - h - 8)))
    }

    private func showApprovalBubble(id: Int? = nil, command: String, params: [String: Any] = [:]) {
        if approvalView == nil {
            let v = ApprovalBubbleView(frame: .zero)
            v.alphaValue = 0
            v.onAllow = { [weak self] in self?.dismissApproval(.allow, command: command) }
            v.onDeny  = { [weak self] in self?.dismissApproval(.deny,  command: command) }
            petDrag.addSubview(v)
            approvalView = v
        }
        approvalView?.setCommand(command)
        positionApproval()
        approvalView?.animator().alphaValue = 1
        setLookingUp(true)
    }

    private func positionApproval() {
        guard let v = approvalView else { return }
        let centerX = petView.frame.midX
        let bottomY = petView.frame.maxY + 10
        v.frame.origin = NSPoint(
            x: min(max(centerX - v.frame.width / 2, 8), max(8, petDrag.bounds.width - v.frame.width - 8)),
            y: min(max(bottomY, 8), max(8, petDrag.bounds.height - v.frame.height - 8)))
    }

    private enum Decision { case allow, deny }
    private func dismissApproval(_ d: Decision, command: String) {
        // In the real Codex sidecar this writes a JSON file consumed by the
        // codex-app-server client. For the prototype we log to a sidecar log
        // file the user can inspect.
        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Documents/Codex/2026-08-16/atom-hatch-pet-v2-users-yanyuting/work/atom-sidecar/approvals.log")
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "decision": d == .allow ? "allow" : "deny",
            "command": command,
        ]
        let line = (try? JSONSerialization.data(withJSONObject: entry))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        } else {
            try? (line + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        if let id = pendingApprovalId {
            codex?.respondApproval(id: id, decision: d == .allow ? "accept" : "decline")
            pendingApprovalId = nil
        }
        approvalView?.animator().alphaValue = 0
        setLookingUp(false)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            if let img = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "原子") {
                btn.image = img
            } else {
                btn.title = "原子"
            }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "原子说一句", action: #selector(ctxForceNext), keyEquivalent: "a")
        menu.addItem(withTitle: "跳一下", action: #selector(ctxJump), keyEquivalent: "")
        menu.addItem(withTitle: "挥手", action: #selector(ctxWave), keyEquivalent: "")
        menu.addItem(withTitle: "演示授权气泡", action: #selector(ctxDemoApproval), keyEquivalent: "d")
        menu.addItem(NSMenuItem.separator())
        let perm = menu.addItem(withTitle: "开启全局快捷键（辅助功能）", action: #selector(ctxAccessibilitySettings), keyEquivalent: "")
        perm.target = self
        menu.addItem(NSMenuItem.separator())
        let vis = menu.addItem(withTitle: "隐藏原子", action: #selector(ctxToggleVisible), keyEquivalent: "h")
        vis.tag = 100
        visibilityItems.append(vis)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "放大原子", action: #selector(ctxZoomIn), keyEquivalent: "")
        menu.addItem(withTitle: "缩小原子", action: #selector(ctxZoomOut), keyEquivalent: "")
        menu.addItem(withTitle: "重置大小", action: #selector(ctxResetZoom), keyEquivalent: "")
        menu.addItem(withTitle: "退出", action: #selector(ctxQuit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item

        // Global keyDown monitor needs Accessibility trust; harmless if not granted.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags
            if event.keyCode == 0, mods.contains([.control, .option]) {
                self?.forceNextBubble()
            } else if event.keyCode == 6, mods.contains([.control, .option]) {
                self?.ctxDemoApproval()
            } else if event.keyCode == 4, mods.contains([.control, .option]) {
                self?.ctxToggleVisible()
            }
        }
    }

    @objc private func ctxAccessibilitySettings() {
        if AXIsProcessTrusted() {
            showBubble(text: "全局快捷键已就绪，按 Control+Option+A")
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            showBubble(text: "请在辅助功能里允许原子")
        }
    }

    private func registerHotkeys() {
        let ctrlOpt = UInt32(controlKey | optionKey)
        HotkeyManager.shared.register(id: 1, keyCode: 0, modifiers: ctrlOpt) { [weak self] in
            self?.forceNextBubble()
        }
        HotkeyManager.shared.register(id: 2, keyCode: 6, modifiers: ctrlOpt) { [weak self] in
            self?.ctxDemoApproval()
        }
        print("hotkeys: Control+Option+A next bubble, Control+Option+Z approval demo")
    }

    private func setupCodex(cwd: String, approvalPolicy: String, sandbox: String) {
        let bridge = CodexBridge()
        bridge.onReady = { [weak self] tid in
            self?.showBubble(text: "Codex 就绪，输入 prompt 吧")
        }
        bridge.onApproval = { [weak self] id, params in
            self?.pendingApprovalId = id
            let command = (params["command"] as? String)
                ?? (params["reason"] as? String)
                ?? "需要授权"
            self?.showApprovalBubble(id: id, command: command, params: params)
            let env = ProcessInfo.processInfo.environment
            if let auto = env["ATOM_AUTO_APPROVE"], auto == "accept" || auto == "decline" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.dismissApproval(auto == "accept" ? .allow : .deny, command: command)
                }
            }
        }
        bridge.onAgentMessage = { [weak self] text in
            let short = String(text.prefix(60))
            self?.showBubble(text: short)
        }
        bridge.onTurnCompleted = { [weak self] in
            self?.pendingApprovalId = nil
        }
        bridge.onError = { [weak self] msg in
            self?.showBubble(text: "codex: " + msg)
        }
        codex = bridge
        bridge.start(cwd: cwd, approvalPolicy: approvalPolicy, sandbox: sandbox)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let self else { return }
                DispatchQueue.main.async { self.codex?.startTurn(prompt: trimmed) }
            }
        }
    }

    private func installContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "立刻说一句话", action: #selector(ctxForceNext), keyEquivalent: "")
        menu.addItem(withTitle: "挥手", action: #selector(ctxWave), keyEquivalent: "")
        menu.addItem(withTitle: "切换实时生成", action: #selector(ctxTriggerLive), keyEquivalent: "")
        menu.addItem(withTitle: "演示授权气泡", action: #selector(ctxDemoApproval), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let vis = menu.addItem(withTitle: "隐藏原子", action: #selector(ctxToggleVisible), keyEquivalent: "")
        vis.tag = 100
        visibilityItems.append(vis)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "放大原子", action: #selector(ctxZoomIn), keyEquivalent: "")
        menu.addItem(withTitle: "缩小原子", action: #selector(ctxZoomOut), keyEquivalent: "")
        menu.addItem(withTitle: "重置大小", action: #selector(ctxResetZoom), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(ctxQuit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        window.contentView?.menu = menu
        petDrag.menu = menu
    }
    @objc private func ctxForceNext() { forceNextBubble() }
    @objc private func ctxJump() { playJump() }
    @objc private func ctxWave() { playWave() }
    @objc private func ctxTriggerLive() { triggerLiveGeneration() }
    @objc private func ctxZoomIn() { setPetScale(petScale + 0.15) }
    @objc private func ctxZoomOut() { setPetScale(petScale - 0.15) }
    @objc private func ctxResetZoom() { setPetScale(1) }
    @objc private func ctxToggleVisible() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
        let title = window.isVisible ? "隐藏原子" : "显示原子"
        for item in visibilityItems { item.title = title }
        AppLog.log("toggle visible -> \(window.isVisible)")
    }
    private func setPetScale(_ scale: CGFloat) {
        petScale = min(1.8, max(0.6, scale))
        let w = 192 * petScale
        let h = 208 * petScale
        petView.frame = NSRect(x: (petDrag.bounds.width - w) / 2,
                               y: 16,
                               width: w,
                               height: h)
        bubbleView.setScale(petScale)
        if bubbleView.frame.width > 0 {
            positionBubble(forSpeech: true, text: nil)
        }
        if let v = approvalView {
            v.setScale(petScale)
            positionApproval()
        }
        AppLog.log("pet scale -> \(petScale)")
    }
    @objc private func ctxDemoApproval() {
        AppLog.log("ctxDemoApproval called")
        showApprovalBubble(command: "rm -rf /tmp/atom-demo && echo \"demo command\"")
    }
    @objc private func ctxQuit() { NSApp.terminate(nil) }

    private func writeSnapshot(to path: String) {
        guard let view = window.contentView else { return }
        window.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        guard let r = rep else { return }
        view.cacheDisplay(in: view.bounds, to: r)
        if let png = r.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
