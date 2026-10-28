import AppKit
import ServiceManagement

let DIR = NSString(string: "~/.claude-waiting").expandingTildeInPath
let SHOW_AFTER_SECONDS: TimeInterval = 60 // a finished turn only shows once you have clearly walked away
let POLL_SECONDS: TimeInterval = 2
let WIDTH: CGFloat = 330
let MARGIN: CGFloat = 12
let GAP: CGFloat = 10
let SOUND = "Glass" // any name from /System/Library/Sounds
let RADIUS: CGFloat = 18
let ART_HEADER_H: CGFloat = 64

// User settings, from the menu bar icon.
let prefs = UserDefaults.standard
var style: String { prefs.string(forKey: "style") ?? "default" } // "default" | "compact" | "art"
var boldOutline: Bool { prefs.bool(forKey: "boldOutline") }
var outlineColor: NSColor { colorFromHex(prefs.string(forKey: "outlineColor") ?? "#4A9EFF") }
var restH: CGFloat { style == "compact" ? 52 : style == "art" ? 150 : 132 } // card height before hover

let colorFromHex = { (hex: String) -> NSColor in
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return .gray }
    return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let hexFromColor = { (c: NSColor) -> String in
    let c = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

struct Waiting {
    let sessionId: String, kind: String, folder: String, tty: String, label: String, name: String, tabId: String, appId: String
    let reason: String, title: String, snippet: String, at: Date, path: String
}

let loadWaiting = { () -> [Waiting] in
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: DIR) else { return [] }
    var out: [Waiting] = []
    for name in names where name.hasSuffix(".json") {
        let path = DIR + "/" + name
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        let str = { (key: String) in json[key] as? String ?? "" }
        out.append(Waiting(sessionId: str("session_id"), kind: str("kind"), folder: str("folder"), tty: str("tty"),
                           label: str("label"), name: str("name"), tabId: str("tab_id"), appId: str("app_id"), reason: str("reason"), title: str("title"), snippet: str("snippet"),
                           at: Date(timeIntervalSince1970: (json["at"] as? Double) ?? 0), path: path))
    }
    return out
        .filter { $0.reason != "done" || Date().timeIntervalSince($0.at) >= SHOW_AFTER_SECONDS }
        .sorted { $0.at < $1.at }
}

let BUNDLE = Bundle.main.bundlePath
let RESOURCES = Bundle.main.resourcePath ?? ""
// From the repo, ClaudeJump.app sits next to us and already holds its Accessibility grant. Downloaded, it is nested inside.
let JUMP_APP: String = {
    let sibling = (BUNDLE as NSString).deletingLastPathComponent + "/ClaudeJump.app"
    return FileManager.default.fileExists(atPath: sibling) ? sibling : BUNDLE + "/Contents/Helpers/ClaudeJump.app"
}()

// Claude keeps the live session name (auto or /rename) here; the row's copy may be stale.
let sessionName = { (sid: String) -> String in
    let dir = NSString(string: "~/.claude/sessions").expandingTildeInPath
    for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: dir + "/" + f),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["sessionId"] as? String == sid, json["nameSource"] as? String != "derived",
              let name = json["name"] as? String, !name.isEmpty else { continue }
        return name
    }
    return ""
}

// Called when a row appears and right before Open, so the tab carries the id whatever renamed it since.
let setTabTitle = { (w: Waiting) in
    guard !w.tabId.isEmpty, let tty = FileHandle(forWritingAtPath: "/dev/" + w.tty) else { return }
    let live = sessionName(w.sessionId)
    let name = live.isEmpty ? (w.name.isEmpty ? w.folder : w.name) : live
    let mark = w.reason == "done" || w.reason == "idle" ? "✅" : "❓"
    tty.write("\u{1B}]0;\(mark) \(name) #\(w.tabId)\u{07}".data(using: .utf8)!)
}

// Every VS Code window runs the claude-waiting-focus extension and writes its port to this folder.
// Ask each one to focus the tty; the owner answers 200 with its folder, which we then open to raise it.
let focusInVSCode = { (w: Waiting) in
    let dir = DIR + "/vscode"
    for port in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/focus?tty=\(w.tty)") else { continue }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let done = DispatchSemaphore(value: 0)
        var folder: String? = nil
        var dead = false
        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil { dead = true }
            if (response as? HTTPURLResponse)?.statusCode == 200 { folder = String(data: data ?? Data(), encoding: .utf8) }
            done.signal()
        }.resume()
        done.wait()
        if dead { try? FileManager.default.removeItem(atPath: dir + "/" + port) }
        if folder != nil { return }
    }
    // No window claimed it (extension not loaded yet?): at least bring VS Code forward.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-b", "com.microsoft.VSCode"]
    try? open.run()
}

let openSession = { (w: Waiting) in
    if w.kind == "app" {
        NSWorkspace.shared.open(URL(string: "claude://code/continue?session=\(w.appId.isEmpty ? "local_" + w.sessionId : w.appId)")!)
        return
    }
    guard !w.tty.isEmpty else { return }
    if w.kind == "vscode" {
        DispatchQueue.global().async { focusInVSCode(w) }
        return
    }
    let script = w.kind == "iTerm.app" ? "jump-iterm.applescript" : w.kind == "Apple_Terminal" ? "jump-terminal.applescript" : ""
    if script.isEmpty { return }
    // ClaudeJump is launched through LaunchServices so macOS treats it as its own app for permissions.
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = [RESOURCES + "/" + script, w.tty]
    config.activates = false
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: JUMP_APP), configuration: config)
}

let EXTERNAL_LINK_ICON: NSImage? = {
    let img = NSImage(contentsOfFile: RESOURCES + "/external-link.svg")
    img?.size = NSSize(width: 20, height: 20)
    return img
}()

let font = { (size: CGFloat, bold: Bool) -> NSFont in
    NSFont(name: bold ? "AvenirNext-DemiBold" : "AvenirNext-Medium", size: size) ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
}

// Header art per source for the Art style. The same picture always means the same place.
let headerImage = { (kind: String) -> NSImage? in
    let name = kind == "vscode" ? "header-vscode" : kind == "app" ? "header-app" : "header-other"
    return NSImage(contentsOfFile: RESOURCES + "/" + name + ".png")
}

let label = { (text: String, font: NSFont, color: NSColor, frame: NSRect) -> NSTextField in
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.frame = frame
    l.lineBreakMode = .byTruncatingTail
    return l
}

let wrapped = { (text: String, font: NSFont, color: NSColor, frame: NSRect) -> NSTextField in
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = font
    l.textColor = color
    l.frame = frame
    l.isSelectable = false
    l.maximumNumberOfLines = 4
    l.lineBreakMode = .byWordWrapping
    l.cell?.truncatesLastVisibleLine = true
    return l
}

let textHeight = { (text: String, f: NSFont, width: CGFloat, maxLines: Int) -> CGFloat in
    let r = NSAttributedString(string: text, attributes: [.font: f])
        .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let line = ceil(f.ascender - f.descender + f.leading)
    return min(ceil(r.height), line * CGFloat(maxLines)) + 2
}

// A card keeps its views between renders. Motion is driven by the widget's ticker: every frame the current
// values move a fraction of the way to the targets, so a new target mid-motion never snaps. y runs from the top.
final class CardView: NSView {
    let sessionId: String
    var onHover: (() -> Void)?
    var restH: CGFloat = 0
    var extraH: CGFloat = 0
    var reveal: [NSView] = []              // visible only while unfolded
    var hide: [NSView] = []                // visible only while folded
    var bottom: [(NSView, CGFloat)] = []   // anchored to the bottom edge: (view, distance from its top to the bottom)
    var onOpen: (() -> Void)?
    var curY: CGFloat = 0, curH: CGFloat = 0, curReveal: CGFloat = 0, curAlpha: CGFloat = 0
    var targetY: CGFloat = 0, targetH: CGFloat = 0, targetReveal: CGFloat = 0, targetAlpha: CGFloat = 1
    var targetAt: TimeInterval = 0         // the wave: cards below the unfolded one start a little later
    init(sessionId: String) { self.sessionId = sessionId; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseExited(with event: NSEvent) { onHover?() }
    // Faded-out buttons must not catch clicks meant for the card.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        if let v = v, v !== self, v.alphaValue < 0.5 { return self }
        return v
    }
    // A click anywhere on the card opens the chat; a drag off the card does nothing.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    func jump() { curY = targetY; curH = targetH; curReveal = targetReveal; curAlpha = targetAlpha; render() }
    // One frame of motion. Returns true while anything is still moving.
    func step(_ now: TimeInterval) -> Bool {
        if now < targetAt { return true }
        let k: CGFloat = 0.22
        var moving = false
        let pull = { (cur: inout CGFloat, target: CGFloat) in
            if abs(target - cur) < 0.3 { cur = target } else { cur += (target - cur) * k; moving = true }
        }
        pull(&curY, targetY); pull(&curH, targetH); pull(&curReveal, targetReveal); pull(&curAlpha, targetAlpha)
        render()
        return moving
    }
    func render() {
        frame = NSRect(x: 0, y: curY, width: WIDTH, height: curH)
        alphaValue = curAlpha
        // Buttons and the long text live in the second half of the unfold, so they are gone early on the way back.
        let late = max(0, min(1, (curReveal - 0.5) * 2))
        for v in reveal { v.alphaValue = late }
        for v in hide { v.alphaValue = 1 - late }
        for (v, d) in bottom { v.frame.origin.y = curH - d }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// A button that brightens on hover and can nudge a little (the Open arrow moves toward its corner).
final class HoverButton: NSButton {
    var normalBG = NSColor.white.withAlphaComponent(0.08).cgColor
    var hoverBG = NSColor.white.withAlphaComponent(0.22).cgColor
    var nudge = CGSize.zero
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { set(hover: true) }
    override func mouseExited(with event: NSEvent) { set(hover: false) }
    func set(hover: Bool) {
        guard let l = layer else { return }
        let bg = hover ? hoverBG : normalBG
        let t = hover ? CATransform3DMakeTranslation(nudge.width, nudge.height, 0) : CATransform3DIdentity
        // AppKit turns implicit layer animations off, so animate by hand from wherever the layer is right now.
        for (key, from, to) in [("backgroundColor", l.presentation()?.backgroundColor ?? l.backgroundColor, bg as Any),
                                ("transform", l.presentation()?.transform ?? l.transform, t as Any)] {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = 0.14
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            l.add(a, forKey: key)
        }
        l.backgroundColor = bg
        l.transform = t
    }
}

let PINK = NSColor(red: 1, green: 0.42, blue: 0.62, alpha: 1)
let GREY = NSColor.white.withAlphaComponent(0.55)
let DIM = NSColor.white.withAlphaComponent(0.4)
let BODY = NSColor(white: 0.11, alpha: 1)

// Debugging: CLAUDE_WAITING_DEBUG=1 prints every hover/layout step; CLAUDE_WAITING_CAPTURE=1 also saves the
// panel to ~/.claude-waiting/frames/ 25 times a second so the motion can be inspected frame by frame.
let DEBUG = ProcessInfo.processInfo.environment["CLAUDE_WAITING_DEBUG"] != nil
let CAPTURE = ProcessInfo.processInfo.environment["CLAUDE_WAITING_CAPTURE"] != nil
let t0 = Date()
let dlog = { (s: String) in if DEBUG { print(String(format: "%7.3f ", Date().timeIntervalSince(t0)) + s) } }
var frameNo = 0
let captureFrame = { (panel: NSPanel) in
    guard panel.isVisible, let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming]) else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let dir = DIR + "/frames"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    frameNo += 1
    FileManager.default.createFile(atPath: dir + String(format: "/%04d_%.3f.png", frameNo, Date().timeIntervalSince(t0)), contents: png)
}

// ---- one-time setup for a downloaded copy: hooks into ~/.claude/settings.json, VS Code extension ----

let HOME = NSHomeDirectory()
let CLAUDE_SETTINGS = HOME + "/.claude/settings.json"

let hooksInstalled = { () -> Bool in
    guard let d = FileManager.default.contents(atPath: CLAUDE_SETTINGS), let s = String(data: d, encoding: .utf8) else { return false }
    return s.contains("claude-waiting") || s.contains("ClaudeWaiting.app")
}

let writeJSON = { (path: String, root: Any) in
    let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path + ".bak-waiting")
        try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak-waiting")
    }
    FileManager.default.createFile(atPath: path, contents: data)
}

let setup = { () -> String in
    var report: [String] = []
    var root: [String: Any] = [:]
    if let d = FileManager.default.contents(atPath: CLAUDE_SETTINGS) {
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return "Could not read ~/.claude/settings.json as JSON. Nothing was changed." }
        root = j
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    for (event, v) in hooks {
        guard var arr = v as? [[String: Any]] else { continue }
        arr.removeAll { e in
            let cmd = (e["hooks"] as? [[String: Any]])?.first?["command"] as? String ?? ""
            return cmd.contains("claude-waiting") || cmd.contains("ClaudeWaiting.app")
        }
        hooks[event] = arr
    }
    let wanted: [(String, String, String?)] = [
        ("SessionStart", "start", nil), ("UserPromptSubmit", "prompt", nil), ("Stop", "stop", nil), ("Notification", "notify", nil),
        ("SessionEnd", "end", nil), ("PreToolUse", "question", "AskUserQuestion"), ("PostToolUse", "answered", "AskUserQuestion"),
    ]
    for (event, arg, matcher) in wanted {
        var entry: [String: Any] = ["hooks": [["type": "command", "command": "\"\(RESOURCES)/hook\" \(arg)"]]]
        if let m = matcher { entry["matcher"] = m }
        hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [entry]
    }
    root["hooks"] = hooks
    var env = root["env"] as? [String: Any] ?? [:]
    env["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] = "1"
    root["env"] = env
    writeJSON(CLAUDE_SETTINGS, root)
    report.append("Hooks added to ~/.claude/settings.json (backup: settings.json.bak-waiting). Restart your Claude sessions.")

    let code = ["/usr/local/bin/code", "/opt/homebrew/bin/code", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    if let code = code {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: code)
        p.arguments = ["--install-extension", RESOURCES + "/claude-waiting-focus.vsix", "--force"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        report.append(p.terminationStatus == 0 ? "VS Code extension installed. Reload your VS Code windows." : "VS Code extension install failed (code \(p.terminationStatus)).")
        let vs = HOME + "/Library/Application Support/Code/User/settings.json"
        if let d = FileManager.default.contents(atPath: vs), var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            j["terminal.integrated.tabs.title"] = "${process}"
            j["terminal.integrated.tabs.description"] = "${sequence}"
            writeJSON(vs, j)
        } else {
            report.append("Could not edit VS Code settings.json (comments?). Add by hand: \"terminal.integrated.tabs.title\": \"${process}\", \"terminal.integrated.tabs.description\": \"${sequence}\".")
        }
    } else {
        report.append("VS Code CLI not found, extension skipped. Run 'Install hooks' again after enabling Shell Command: Install 'code' in VS Code.")
    }
    report.append("For iTerm2 / Terminal jumps, add ClaudeJump.app (inside this app's Contents/Helpers) under System Settings › Privacy & Security › Accessibility.")
    return report.joined(separator: "\n\n")
}

final class Widget: NSObject, NSApplicationDelegate {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: WIDTH, height: 134),
                        styleMask: [.nonactivatingPanel, .borderless, .utilityWindow], backing: .buffered, defer: false)
    let content = FlippedView()
    var ticker: Timer? = nil
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var shown: [Waiting] = []
    var visible: Set<String> = []
    var hoveredId: String? = nil
    var cards: [String: CardView] = [:]
    var keys: [String: String] = [:]

    func applicationDidFinishLaunching(_: Notification) {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        content.wantsLayer = true
        panel.contentView = content
        panel.appearance = NSAppearance(named: .darkAqua)
        statusItem.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Claude Waiting")
        buildMenu()
        Timer.scheduledTimer(withTimeInterval: POLL_SECONDS, repeats: true) { _ in self.refresh() }
        if CAPTURE { Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in captureFrame(self.panel) } }
        refresh()
        if !hooksInstalled() && !prefs.bool(forKey: "setupOffered") {
            prefs.set(true, forKey: "setupOffered")
            installClicked()
        }
    }

    func buildMenu() {
        let m = NSMenu()
        let item = { (title: String, action: Selector, on: Bool) -> NSMenuItem in
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            return i
        }
        m.addItem(item("Default cards", #selector(styleDefault), style == "default"))
        m.addItem(item("Compact cards", #selector(styleCompact), style == "compact"))
        m.addItem(item("Art cards", #selector(styleArt), style == "art"))
        m.addItem(.separator())
        m.addItem(item("Thin outline", #selector(outlineThin), !boldOutline))
        m.addItem(item("Bold outline", #selector(outlineBold), boldOutline))
        m.addItem(item("Outline colour…", #selector(pickColor), false))
        m.addItem(.separator())
        m.addItem(item("Start at login", #selector(toggleLogin), SMAppService.mainApp.status == .enabled))
        m.addItem(item("Install Claude Code hooks…", #selector(installClicked), false))
        m.addItem(.separator())
        m.addItem(item("Quit Claude Waiting", #selector(NSApplication.terminate(_:)), false))
        statusItem.menu = m
    }

    func settingsChanged() { buildMenu(); if sync() { place(animated: false) } }
    @objc func styleDefault() { prefs.set("default", forKey: "style"); settingsChanged() }
    @objc func styleCompact() { prefs.set("compact", forKey: "style"); settingsChanged() }
    @objc func styleArt() { prefs.set("art", forKey: "style"); settingsChanged() }
    @objc func outlineThin() { prefs.set(false, forKey: "boldOutline"); settingsChanged() }
    @objc func outlineBold() { prefs.set(true, forKey: "boldOutline"); settingsChanged() }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        buildMenu()
    }
    @objc func pickColor() {
        let p = NSColorPanel.shared
        p.setTarget(self)
        p.setAction(#selector(colorChanged(_:)))
        p.showsAlpha = false
        p.color = outlineColor
        NSApp.activate(ignoringOtherApps: true)
        p.orderFront(nil)
    }
    // Picking a colour is only visible on the bold outline, so switch to it.
    @objc func colorChanged(_ p: NSColorPanel) {
        prefs.set(hexFromColor(p.color), forKey: "outlineColor")
        prefs.set(true, forKey: "boldOutline")
        settingsChanged()
    }
    @objc func installClicked() {
        NSApp.activate(ignoringOtherApps: true)
        let ask = NSAlert()
        ask.messageText = "Set up Claude Waiting?"
        ask.informativeText = "This adds hooks to ~/.claude/settings.json so Claude Code reports sessions that are waiting on you, and installs a small VS Code extension that jumps to the right terminal tab. A backup of each file it edits is kept next to it."
        ask.addButton(withTitle: "Install")
        ask.addButton(withTitle: "Not now")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let done = NSAlert()
        done.messageText = "Claude Waiting setup"
        done.informativeText = setup()
        done.runModal()
    }

    // Rest positions, top-down from the panel's top edge; the panel keeps its top where the user dragged it.
    func layout() -> (left: CGFloat, top: CGFloat, tops: [CGFloat]) {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let left = panel.isVisible ? panel.frame.minX : screen.minX + MARGIN
        let top = panel.isVisible ? panel.frame.maxY : screen.maxY - MARGIN
        var tops: [CGFloat] = []
        var t: CGFloat = 0
        for _ in shown { tops.append(t); t += restH + GAP }
        return (left, top, tops)
    }

    // Hover is read from the pointer position, not tracked state, so a rebuild never gets it wrong.
    // The gap between two cards counts as still hovering the last one, so crossing it does not fold and unfold.
    func hoveredIndex() -> Int? {
        let L = layout()
        let mouse = NSEvent.mouseLocation
        let rect = { (i: Int, h: CGFloat) in NSRect(x: L.left, y: L.top - L.tops[i] - h, width: WIDTH, height: h) }
        let prev = hoveredId.flatMap { id in shown.firstIndex { $0.sessionId == id } }
        if let i = prev, let c = cards[shown[i].sessionId], rect(i, c.restH + c.extraH).contains(mouse) { return i }
        if let i = shown.indices.first(where: { rect($0, restH).contains(mouse) }) { return i }
        if prev != nil, panel.frame.contains(mouse) { return prev }
        return nil
    }

    func hoverChanged() {
        guard !shown.isEmpty else { return }
        let h = hoveredIndex().map { shown[$0].sessionId }
        dlog("hoverChanged -> \(h?.prefix(8) ?? "none") (was \(hoveredId?.prefix(8) ?? "none"))")
        if h != hoveredId { place(animated: true) }
    }

    func refresh() {
        shown = loadWaiting()
        let fresh = shown.filter { !visible.contains($0.sessionId) }
        fresh.forEach(setTabTitle)
        if !fresh.isEmpty { NSSound(named: SOUND)?.play() }
        visible = Set(shown.map { $0.sessionId })
        if sync() { place(animated: true) }
    }

    // Rebuild only the cards whose content changed. Returns true if anything did.
    func sync() -> Bool {
        var changed = false
        let ids = Set(shown.map { $0.sessionId })
        for id in cards.keys where !ids.contains(id) {
            cards[id]?.removeFromSuperview()
            cards[id] = nil
            keys[id] = nil
            changed = true
        }
        for w in shown {
            let key = [w.reason, w.snippet, w.name, w.title, w.folder, sessionName(w.sessionId), "\(Int(Date().timeIntervalSince(w.at) / 60))",
                       style, boldOutline ? "b" : "t", hexFromColor(outlineColor)].joined(separator: "|")
            if keys[w.sessionId] == key { continue }
            let c = card(w)
            if let old = cards[w.sessionId] {
                // A rebuilt card picks up where the old one was, so a minute ticking over is invisible.
                (c.curY, c.curH, c.curReveal, c.curAlpha) = (old.curY, old.curH, old.curReveal, old.curAlpha)
                c.render()
                old.removeFromSuperview()
            }
            content.addSubview(c)
            cards[w.sessionId] = c
            keys[w.sessionId] = key
            dlog("rebuilt card \(w.sessionId.prefix(8))")
            changed = true
        }
        return changed
    }

    func setPanelHeight(_ h: CGFloat) {
        let L = layout()
        panel.setFrame(NSRect(x: L.left, y: L.top - h, width: WIDTH, height: h), display: true)
    }

    // Sets every card's target. The ticker then moves them there.
    func place(animated: Bool) {
        if shown.isEmpty { panel.orderOut(nil); hoveredId = nil; return }
        let hovered = hoveredIndex()
        hoveredId = hovered.map { shown[$0].sessionId }
        let now = Date().timeIntervalSinceReferenceDate
        var y: CGFloat = 0
        var heights: [Int] = []
        for (i, w) in shown.enumerated() {
            let c = cards[w.sessionId]!
            let h = c.restH + (i == hovered ? c.extraH : 0)
            heights.append(Int(h))
            c.targetY = y
            c.targetH = h
            c.targetReveal = i == hovered ? 1 : 0
            c.targetAlpha = 1
            c.targetAt = (animated && hovered != nil && i > hovered!) ? now + 0.03 * Double(i - hovered!) : 0
            if !animated || !panel.isVisible { c.jump() }
            y += h + GAP
        }
        dlog("place animated=\(animated) hovered=\(hovered ?? -1) heights=\(heights) panel=\(panel.frame)")
        if !panel.isVisible { setPanelHeight(y - GAP) }
        panel.orderFrontRegardless()
        if ticker == nil {
            ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in self.tick() }
            RunLoop.main.add(ticker!, forMode: .common)
        }
    }

    func tick() {
        let now = Date().timeIntervalSinceReferenceDate
        var moving = false
        for c in cards.values where c.step(now) { moving = true }
        // The panel is invisible, so it just stays tall enough for wherever the cards are or are going.
        let needed = cards.values.map { max($0.curY + $0.curH, $0.targetY + $0.targetH) }.max() ?? 0
        if abs(panel.frame.height - needed) > 0.5 { setPanelHeight(needed) }
        // The window shadow is cached from the last shape; without this it lingers as a dark outline while cards move.
        panel.invalidateShadow()
        if !moving { ticker?.invalidate(); ticker = nil }
    }

    func card(_ w: Waiting) -> CardView {
        let view = CardView(sessionId: w.sessionId)
        view.onHover = { [weak self] in self?.hoverChanged() }
        view.wantsLayer = true
        view.layer?.cornerRadius = RADIUS
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = BODY.cgColor
        view.layer?.borderWidth = boldOutline ? 2.5 : 1
        view.layer?.borderColor = (boldOutline ? outlineColor : NSColor(white: 0.28, alpha: 1)).cgColor
        view.restH = restH

        let live = sessionName(w.sessionId)
        // Unnamed sessions fall back to their first prompt, so the card never repeats the repo name.
        let chat = !live.isEmpty ? live : (!w.name.isEmpty && w.name != w.folder) ? w.name : !w.title.isEmpty ? w.title : w.folder
        let source: String
        switch w.kind {
        case "app": source = "Claude app"
        case "vscode": source = "VS Code · \(w.tabId)"
        case "iTerm.app": source = "iTerm · \(w.tabId)"
        case "Apple_Terminal": source = "Terminal · \(w.tabId)"
        default: source = "\(w.kind) · \(w.tabId)"
        }
        let detail = w.snippet.isEmpty ? w.title : w.snippet
        let mins = Int(Date().timeIntervalSince(w.at) / 60)
        let big = mins < 60 ? "\(mins)" : "\(mins / 60)"
        let unit = mins < 60 ? "min" : "hr"
        let needsYou = w.reason == "question" || w.reason == "permission"
        let status = ["done": "Done", "idle": "Idle", "question": "Needs you", "permission": "Permission"][w.reason] ?? "Waiting"
        let H = restH

        if style == "art" {
            let art = CALayer()
            art.frame = CGRect(x: 0, y: 0, width: WIDTH, height: ART_HEADER_H)
            art.contents = headerImage(w.kind)
            art.contentsGravity = .resizeAspectFill
            art.masksToBounds = true
            view.layer?.addSublayer(art)
            // The dark body with a folder-style tab rising into the header on the left.
            let bodyTop = ART_HEADER_H
            let tabTop = bodyTop - 22
            let titleW = NSAttributedString(string: chat, attributes: [.font: font(16, true)]).size().width
            let tabW = min(max(titleW + 46, 140), WIDTH - 96)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: H))
            path.addLine(to: CGPoint(x: 0, y: tabTop + RADIUS))
            path.addQuadCurve(to: CGPoint(x: RADIUS, y: tabTop), control: CGPoint(x: 0, y: tabTop))
            path.addLine(to: CGPoint(x: tabW - 14, y: tabTop))
            path.addCurve(to: CGPoint(x: tabW + 30, y: bodyTop), control1: CGPoint(x: tabW + 8, y: tabTop), control2: CGPoint(x: tabW + 6, y: bodyTop))
            path.addLine(to: CGPoint(x: WIDTH - RADIUS, y: bodyTop))
            path.addQuadCurve(to: CGPoint(x: WIDTH, y: bodyTop + RADIUS), control: CGPoint(x: WIDTH, y: bodyTop))
            path.addLine(to: CGPoint(x: WIDTH, y: H))
            path.closeSubpath()
            let body = CAShapeLayer()
            body.path = path
            body.fillColor = BODY.cgColor
            view.layer?.addSublayer(body)
        }

        // Whole card opens the session; the ✕ dismisses it.
        view.onOpen = { [weak self] in self?.open(w.sessionId) }

        let go = HoverButton(title: "", target: self, action: #selector(openClicked(_:)))
        go.isBordered = false
        go.wantsLayer = true
        go.image = EXTERNAL_LINK_ICON
        go.imagePosition = .imageOnly
        go.layer?.backgroundColor = go.normalBG
        go.layer?.cornerRadius = 9
        go.nudge = CGSize(width: 2, height: -2)

        let dismiss = HoverButton(title: "", target: self, action: #selector(closeClicked(_:)))
        dismiss.isBordered = false
        dismiss.wantsLayer = true
        dismiss.attributedTitle = NSAttributedString(string: "✕", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor(white: 0.85, alpha: 1)])
        if style == "art" { dismiss.normalBG = NSColor.black.withAlphaComponent(0.35).cgColor; dismiss.hoverBG = NSColor.black.withAlphaComponent(0.7).cgColor }
        dismiss.layer?.backgroundColor = dismiss.normalBG
        dismiss.layer?.cornerRadius = 11

        switch style {
        case "compact":
            // Structure 7: dot · name · folder · time, snippet under; hover unfolds the snippet and adds a button row.
            let sh = textHeight(detail, font(12, false), WIDTH - 46, 4)
            view.extraH = max(0, sh - 15) + 40
            let dot = NSView(frame: NSRect(x: 16, y: 16, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = (needsYou ? PINK : NSColor(white: 0.45, alpha: 1)).cgColor
            view.addSubview(dot)
            let line = NSMutableAttributedString(string: chat, attributes: [.font: font(14, true), .foregroundColor: NSColor.white])
            line.append(NSAttributedString(string: "  ·  " + w.folder, attributes: [.font: font(13, false), .foregroundColor: GREY]))
            let l1 = NSTextField(labelWithAttributedString: line)
            l1.lineBreakMode = .byTruncatingTail
            l1.frame = NSRect(x: 30, y: 11, width: WIDTH - 30 - 16 - 48, height: 18)
            view.addSubview(l1)
            let t = label("\(big)\(unit == "min" ? "m" : "h")", font(13, true), .white, NSRect(x: WIDTH - 62, y: 11, width: 46, height: 18))
            t.alignment = .right
            view.addSubview(t)
            let short = label(detail, font(12, false), DIM, NSRect(x: 30, y: 31, width: WIDTH - 46, height: 15))
            let full = wrapped(detail, font(12, false), GREY, NSRect(x: 30, y: 31, width: WIDTH - 46, height: sh))
            view.addSubview(short)
            view.addSubview(full)
            view.hide.append(short)
            let meta = NSMutableAttributedString(string: source + "  ·  ", attributes: [.font: font(11, true), .foregroundColor: GREY])
            meta.append(NSAttributedString(string: status, attributes: [.font: font(11, true), .foregroundColor: needsYou ? PINK : GREY]))
            let m = NSTextField(labelWithAttributedString: meta)
            m.frame = NSRect(x: 30, y: H - 28, width: WIDTH - 30 - 100, height: 16)
            view.addSubview(m)
            dismiss.frame = NSRect(x: WIDTH - 84, y: H - 31, width: 22, height: 22)
            go.frame = NSRect(x: WIDTH - 48, y: H - 36, width: 32, height: 32)
            view.reveal += [full, m, dismiss, go]
            view.bottom += [(m, 28), (dismiss, 31), (go, 36)]
        case "art":
            dismiss.frame = NSRect(x: 12, y: 10, width: 22, height: 22)
            let src = label(source, font(13, true), .white, NSRect(x: WIDTH - 176, y: 16, width: 160, height: 20))
            src.alignment = .right
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 6
            src.shadow = shadow
            view.addSubview(src)
            let titleW = NSAttributedString(string: chat, attributes: [.font: font(16, true)]).size().width
            let tabW = min(max(titleW + 46, 140), WIDTH - 96)
            view.addSubview(label(chat, font(16, true), .white, NSRect(x: 18, y: 48, width: tabW - 36, height: 22)))
            view.addSubview(label(w.folder, font(13, false), GREY, NSRect(x: 18, y: 72, width: WIDTH - 36, height: 18)))
            let sub = label(detail, font(11, false), DIM, NSRect(x: 18, y: 92, width: WIDTH - 36, height: 15))
            sub.toolTip = detail
            view.addSubview(sub)
            let bigLabel = label(big, font(24, true), .white, NSRect(x: 16, y: H - 40, width: 100, height: 30))
            bigLabel.sizeToFit()
            bigLabel.frame.origin.y = H - 40
            view.addSubview(bigLabel)
            view.addSubview(label(unit, font(12, false), .white, NSRect(x: bigLabel.frame.maxX + 3, y: H - 29, width: 40, height: 16)))
            let statusLabel = label(status, font(15, true), needsYou ? PINK : .white, NSRect(x: 100, y: H - 34, width: WIDTH - 100 - 60, height: 20))
            statusLabel.alignment = .center
            view.addSubview(statusLabel)
            go.frame = NSRect(x: WIDTH - 48, y: H - 40, width: 32, height: 32)
        default:
            // Structure 1: big minutes first, status beside it, name · folder, snippet, source; buttons only on hover.
            let sh = textHeight(detail, font(12, false), WIDTH - 32, 4)
            view.extraH = max(0, sh - 16)
            let bigLabel = label(big, font(26, true), .white, NSRect(x: 16, y: 14, width: 100, height: 32))
            bigLabel.sizeToFit()
            bigLabel.frame.origin.y = 14
            view.addSubview(bigLabel)
            let unitLabel = label(unit, font(12, false), .white, NSRect(x: bigLabel.frame.maxX + 3, y: 24, width: 40, height: 16))
            unitLabel.sizeToFit()
            unitLabel.frame.origin.y = 24
            view.addSubview(unitLabel)
            view.addSubview(label(status, font(15, true), needsYou ? PINK : GREY, NSRect(x: unitLabel.frame.maxX + 12, y: 21, width: WIDTH - unitLabel.frame.maxX - 12 - 48, height: 20)))
            dismiss.frame = NSRect(x: WIDTH - 38, y: 18, width: 22, height: 22)
            let line = NSMutableAttributedString(string: chat, attributes: [.font: font(14, true), .foregroundColor: NSColor.white])
            line.append(NSAttributedString(string: "  ·  " + w.folder, attributes: [.font: font(13, false), .foregroundColor: GREY]))
            let l2 = NSTextField(labelWithAttributedString: line)
            l2.lineBreakMode = .byTruncatingTail
            l2.frame = NSRect(x: 16, y: 48, width: WIDTH - 32, height: 18)
            view.addSubview(l2)
            let short = label(detail, font(12, false), DIM, NSRect(x: 16, y: 70, width: WIDTH - 32, height: 16))
            let full = wrapped(detail, font(12, false), GREY, NSRect(x: 16, y: 70, width: WIDTH - 32, height: sh))
            view.addSubview(short)
            view.addSubview(full)
            view.hide.append(short)
            let src = label(source, font(11, true), GREY, NSRect(x: 16, y: H - 34, width: 200, height: 16))
            view.addSubview(src)
            go.frame = NSRect(x: WIDTH - 48, y: H - 42, width: 32, height: 32)
            view.reveal += [full, dismiss, go]
            view.bottom += [(src, 34), (go, 42)]
        }
        view.addSubview(go)
        view.addSubview(dismiss)
        view.targetH = H
        view.render()
        return view
    }

    func cardOf(_ sender: NSView) -> Waiting? {
        var v: NSView? = sender
        while let x = v, !(x is CardView) { v = x.superview }
        guard let id = (v as? CardView)?.sessionId else { return nil }
        return shown.first { $0.sessionId == id }
    }

    @objc func openClicked(_ sender: NSButton) { if let w = cardOf(sender) { open(w.sessionId) } }

    func open(_ id: String) {
        guard let w = shown.first(where: { $0.sessionId == id }) else { return }
        dlog("open \(id.prefix(8))")
        try? FileManager.default.removeItem(atPath: w.path)
        setTabTitle(w)
        openSession(w)
        refresh()
    }

    @objc func closeClicked(_ sender: NSButton) {
        guard let w = cardOf(sender) else { return }
        try? FileManager.default.removeItem(atPath: w.path)
        refresh()
    }
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Widget()
app.delegate = delegate
app.run()
