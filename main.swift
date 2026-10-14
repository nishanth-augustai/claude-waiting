import AppKit

let DIR = NSString(string: "~/.claude-waiting").expandingTildeInPath
let SHOW_AFTER_SECONDS: TimeInterval = 60 // a finished turn only shows once you have clearly walked away
let POLL_SECONDS: TimeInterval = 2
let WIDTH: CGFloat = 330
let MARGIN: CGFloat = 12
let SOUND = "Glass" // any name from /System/Library/Sounds

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

// The repo folder: ClaudeWaiting.app and ClaudeJump.app sit side by side in it.
let WIDGET_DIR = (Bundle.main.bundlePath as NSString).deletingLastPathComponent

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
    config.arguments = [WIDGET_DIR + "/" + script, w.tty]
    config.activates = false
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: WIDGET_DIR + "/ClaudeJump.app"), configuration: config)
}

let CARD_H: CGFloat = 184

let EXTERNAL_LINK_ICON: NSImage? = {
    let img = NSImage(contentsOfFile: (Bundle.main.resourcePath ?? "") + "/external-link.svg")
    img?.size = NSSize(width: 22, height: 22)
    return img
}()
let GAP: CGFloat = 10
let HEADER_H: CGFloat = 84

let font = { (size: CGFloat, bold: Bool) -> NSFont in
    NSFont(name: bold ? "AvenirNext-DemiBold" : "AvenirNext-Medium", size: size) ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
}

// Header art per source, from art/ in the bundle. The same picture always means the same place.
let headerImage = { (kind: String) -> NSImage? in
    let name = kind == "vscode" ? "header-vscode" : kind == "app" ? "header-app" : "header-other"
    return NSImage(contentsOfFile: (Bundle.main.resourcePath ?? "") + "/" + name + ".png")
}

// Header gradient per source: dark edge → main → bright highlight, so the colour alone says where it came from.
let sourceColors = { (kind: String) -> [NSColor] in
    let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat) in NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
    switch kind {
    case "vscode": return [rgb(9, 30, 70), rgb(28, 104, 220), rgb(140, 190, 255)]
    case "app": return [rgb(70, 22, 8), rgb(217, 96, 42), rgb(255, 180, 120)]
    case "iTerm.app": return [rgb(8, 50, 25), rgb(40, 170, 90), rgb(160, 240, 180)]
    case "Apple_Terminal": return [rgb(30, 30, 32), rgb(110, 110, 115), rgb(210, 210, 215)]
    default: return [rgb(70, 15, 45), rgb(220, 70, 140), rgb(255, 170, 210)]
    }
}

let label = { (text: String, font: NSFont, color: NSColor, frame: NSRect) -> NSTextField in
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.frame = frame
    l.lineBreakMode = .byTruncatingTail
    return l
}

final class Widget: NSObject, NSApplicationDelegate {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: WIDTH, height: CARD_H),
                        styleMask: [.nonactivatingPanel, .borderless, .utilityWindow], backing: .buffered, defer: false)
    let content = NSView()
    var shown: [Waiting] = []
    var visible: Set<String> = []

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
        Timer.scheduledTimer(withTimeInterval: POLL_SECONDS, repeats: true) { _ in self.refresh() }
        refresh()
    }

    func refresh() {
        shown = loadWaiting()
        let fresh = shown.filter { !visible.contains($0.sessionId) }
        fresh.forEach(setTabTitle)
        if !fresh.isEmpty { NSSound(named: SOUND)?.play() }
        visible = Set(shown.map { $0.sessionId })
        if shown.isEmpty { panel.orderOut(nil); return }
        let height = CGFloat(shown.count) * (CARD_H + GAP) - GAP
        var origin: NSPoint
        if panel.isVisible {
            origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - height)
        } else {
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: screen.minX + MARGIN, y: screen.maxY - height - MARGIN)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: WIDTH, height: height)), display: true)
        content.subviews.forEach { $0.removeFromSuperview() }
        for (i, w) in shown.enumerated() {
            content.addSubview(card(w, index: i, y: height - CGFloat(i + 1) * CARD_H - CGFloat(i) * GAP))
        }
        panel.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["CLAUDE_WAITING_DEBUG"] != nil { print("rows:", shown.count, "frame:", panel.frame, "visible:", panel.isVisible) }
    }

    func card(_ w: Waiting, index: Int, y: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: y, width: WIDTH, height: CARD_H))
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor

        let art = CALayer()
        art.frame = CGRect(x: 0, y: CARD_H - HEADER_H, width: WIDTH, height: HEADER_H)
        art.contents = headerImage(w.kind)
        art.contentsGravity = .resizeAspectFill
        art.masksToBounds = true
        view.layer?.addSublayer(art)

        // The dark body with a folder-style tab rising into the header on the left.
        let bodyTop = CARD_H - HEADER_H
        let tabTop = bodyTop + 28
        let live = sessionName(w.sessionId)
        // Unnamed sessions fall back to their first prompt, so the card never repeats the repo name.
        let chat = !live.isEmpty ? live : (!w.name.isEmpty && w.name != w.folder) ? w.name : !w.title.isEmpty ? w.title : w.folder
        let titleFont = font(16, true)
        let titleW = NSAttributedString(string: chat, attributes: [.font: titleFont]).size().width
        let tabW = min(max(titleW + 46, 140), WIDTH - 96)
        let r: CGFloat = 18
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: tabTop - r))
        path.addQuadCurve(to: CGPoint(x: r, y: tabTop), control: CGPoint(x: 0, y: tabTop))
        path.addLine(to: CGPoint(x: tabW - 14, y: tabTop))
        path.addCurve(to: CGPoint(x: tabW + 30, y: bodyTop), control1: CGPoint(x: tabW + 8, y: tabTop), control2: CGPoint(x: tabW + 6, y: bodyTop))
        path.addLine(to: CGPoint(x: WIDTH - r, y: bodyTop))
        path.addQuadCurve(to: CGPoint(x: WIDTH, y: bodyTop - r), control: CGPoint(x: WIDTH, y: bodyTop))
        path.addLine(to: CGPoint(x: WIDTH, y: 0))
        path.closeSubpath()
        let body = CAShapeLayer()
        body.path = path
        body.fillColor = NSColor(white: 0.11, alpha: 1).cgColor
        view.layer?.addSublayer(body)

        // Whole card opens the session; the small ✕ in the header dismisses it.
        let open = NSButton(title: "", target: self, action: #selector(openClicked(_:)))
        open.isBordered = false
        open.isTransparent = true
        open.tag = index
        open.frame = view.bounds
        view.addSubview(open)

        let source: String
        switch w.kind {
        case "app": source = "Claude app"
        case "vscode": source = "VS Code\n\(w.tabId)"
        case "iTerm.app": source = "iTerm\n\(w.tabId)"
        case "Apple_Terminal": source = "Terminal\n\(w.tabId)"
        default: source = "\(w.kind)\n\(w.tabId)"
        }
        let where_ = label(source, font(14, true), .white, NSRect(x: WIDTH - 176, y: CARD_H - 56, width: 160, height: 42))
        where_.alignment = .right
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 6
        where_.shadow = shadow
        where_.maximumNumberOfLines = 2
        where_.lineBreakMode = .byWordWrapping
        view.addSubview(where_)

        view.addSubview(label(chat, titleFont, .white, NSRect(x: 18, y: tabTop - 30, width: tabW - 36, height: 22)))
        view.addSubview(label(w.folder, font(13, false), NSColor.white.withAlphaComponent(0.5), NSRect(x: 18, y: tabTop - 50, width: WIDTH - 36, height: 18)))
        let detail = w.snippet.isEmpty ? w.title : w.snippet
        let sub = label(detail, font(11, false), NSColor.white.withAlphaComponent(0.35), NSRect(x: 18, y: tabTop - 70, width: WIDTH - 36, height: 15))
        sub.toolTip = detail
        view.addSubview(sub)

        let mins = Int(Date().timeIntervalSince(w.at) / 60)
        let big = mins < 60 ? "\(mins)" : "\(mins / 60)"
        let unit = mins < 60 ? "min" : "hr"
        let bigLabel = label(big, font(30, true), .white, NSRect(x: 18, y: 12, width: 100, height: 38))
        bigLabel.sizeToFit()
        view.addSubview(bigLabel)
        view.addSubview(label(unit, font(13, false), .white, NSRect(x: bigLabel.frame.maxX + 3, y: 17, width: 50, height: 18)))

        let needsYou = w.reason == "question" || w.reason == "permission"
        let status = ["done": "Done", "idle": "Idle", "question": "Needs you", "permission": "Permission"][w.reason] ?? "Waiting"
        let statusLabel = label(status, font(14, true), needsYou ? NSColor(red: 1, green: 0.72, blue: 0.84, alpha: 1) : .white,
                                NSRect(x: 110, y: 18, width: WIDTH - 110 - 64, height: 20))
        statusLabel.alignment = .center
        view.addSubview(statusLabel)

        let go = NSButton(title: "", target: self, action: #selector(openClicked(_:)))
        go.isBordered = false
        go.wantsLayer = true
        go.tag = index
        go.image = EXTERNAL_LINK_ICON
        go.imagePosition = .imageOnly
        go.frame = NSRect(x: WIDTH - 54, y: 12, width: 36, height: 36)
        view.addSubview(go)

        let dismiss = NSButton(title: "✕", target: self, action: #selector(closeClicked(_:)))
        dismiss.isBordered = false
        dismiss.wantsLayer = true
        dismiss.tag = index
        dismiss.attributedTitle = NSAttributedString(string: "✕", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
        dismiss.frame = NSRect(x: 12, y: CARD_H - 34, width: 22, height: 22)
        dismiss.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dismiss.layer?.cornerRadius = 11
        view.addSubview(dismiss)
        return view
    }

    @objc func openClicked(_ sender: NSButton) {
        let w = shown[sender.tag]
        try? FileManager.default.removeItem(atPath: w.path)
        setTabTitle(w)
        openSession(w)
        refresh()
    }

    @objc func closeClicked(_ sender: NSButton) {
        try? FileManager.default.removeItem(atPath: shown[sender.tag].path)
        refresh()
    }
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Widget()
app.delegate = delegate
app.run()
