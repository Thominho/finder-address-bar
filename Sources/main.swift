import Cocoa
import ServiceManagement

// MARK: - Settings

enum Placement: String {
    case top     // below the toolbar, over Finder's tab bar row
    case bottom  // at the bottom, over Finder's path bar
}

enum Prefs {
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            "placement": Placement.top.rawValue,
            "toolbarHeight": 52.0,
            "titlebarHeight": 28.0,
            "statusBarHeight": 28.0,
            "barHeight": 28.0,
            "pathBarHeight": 30.0,
            "windowCornerRadius": 26.0,
            "sidebarGap": 8.0,
            "offset": 0.0,
            "autoUpdate": true,
        ])
    }

    static var placement: Placement {
        get { Placement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .top }
        set { defaults.set(newValue.rawValue, forKey: "placement") }
    }

    static var offset: CGFloat {
        get { CGFloat(defaults.double(forKey: "offset")) }
        set { defaults.set(Double(newValue), forKey: "offset") }
    }

    static var autoUpdate: Bool {
        get { defaults.bool(forKey: "autoUpdate") }
        set { defaults.set(newValue, forKey: "autoUpdate") }
    }

    static func metric(_ key: String) -> CGFloat { CGFloat(defaults.double(forKey: key)) }
}

/// English by default, Czech on Czech systems.
enum L10n {
    private static let czech = Locale.preferredLanguages.first?.hasPrefix("cs") ?? false
    static func text(_ english: String, _ czech: String) -> String { Self.czech ? czech : english }
}

@MainActor
func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
}

// MARK: - Talking to Finder

struct FinderWindow {
    let id: Int  // same as the window number in the window server
    let path: String  // empty for windows without a folder (Recents, AirDrop…)
    let sidebarWidth: CGFloat
    let toolbarVisible: Bool
    let statusBarVisible: Bool
    let collapsed: Bool
    let bounds: CGRect
    var hasSeveralTabs = false
}

enum FinderError: Error {
    case notAuthorized
    case failed(Int, String)
}

final class FinderBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FinderBridge", qos: .userInitiated)
    private var listScript: NSAppleScript?

    private static let listSource = """
        tell application "Finder"
        	set out to ""
        	repeat with w in (get Finder windows)
        		try
        			set p to ""
        			try
        				set p to POSIX path of ((target of w) as alias)
        			end try
        			set sw to 0
        			set tv to 1
        			set sb to 0
        			set isMin to 0
        			if toolbar visible of w then
        				set sw to sidebar width of w
        			else
        				set tv to 0
        			end if
        			if statusbar visible of w then set sb to 1
        			if collapsed of w then set isMin to 1
        			set b to bounds of w
        			set out to out & (id of w) & tab & sw & tab & tv & tab & sb & tab & isMin & tab & (item 1 of b) & tab & (item 2 of b) & tab & (item 3 of b) & tab & (item 4 of b) & tab & p & linefeed
        		end try
        	end repeat
        	return out
        end tell
        """

    /// Finder windows, front to back.
    func listWindows(_ completion: @escaping @MainActor (Result<[FinderWindow], FinderError>) -> Void) {
        queue.async {
            if self.listScript == nil { self.listScript = NSAppleScript(source: Self.listSource) }
            let result = Self.run(self.listScript).map(Self.parse)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Points the window at a folder.
    func show(folder path: String, inWindow id: Int, _ completion: @escaping @MainActor (Bool) -> Void) {
        execute("""
            set f to (POSIX file "\(Self.quoted(path))") as alias
            tell application "Finder" to set target of Finder window id \(id) to f
            """, completion)
    }

    func raise(windowID id: Int, _ completion: @escaping @MainActor (Bool) -> Void) {
        execute("""
            tell application "Finder"
            	activate
            	set index of Finder window id \(id) to 1
            end tell
            """, completion)
    }

    private func execute(_ source: String, _ completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let ok: Bool
            switch Self.run(NSAppleScript(source: source)) {
            case .success: ok = true
            case .failure(let error):
                NSLog("FinderPathBar: script failed: \(error)")
                ok = false
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
        }
    }

    private static func run(_ script: NSAppleScript?) -> Result<String, FinderError> {
        guard let script else { return .failure(.failed(0, "could not create script")) }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? ""
            return .failure(code == -1743 ? .notAuthorized : .failed(code, message))
        }
        return .success(output.stringValue ?? "")
    }

    private static func parse(_ output: String) -> [FinderWindow] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 10, let id = Int(f[0]),
                  let left = Double(f[5]), let top = Double(f[6]), let right = Double(f[7]), let bottom = Double(f[8])
            else { return nil }
            var path = f[9]
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return FinderWindow(
                id: id, path: path, sidebarWidth: CGFloat(Double(f[1]) ?? 0),
                toolbarVisible: f[2] == "1", statusBarVisible: f[3] == "1", collapsed: f[4] == "1",
                bounds: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Finder's own setting for showing the tab bar in windows with a single tab. With it on, Finder keeps
/// an empty row under the toolbar, which is exactly where the bar goes.
enum FinderTabBar {
    private static let key = "NSWindowTabbingShoudShowTabBarKey-com.apple.finder.TBrowserWindow" as CFString  // AppKit's spelling
    private static let finder = "com.apple.finder" as CFString

    static var isShown: Bool {
        CFPreferencesAppSynchronize(finder)
        return CFPreferencesCopyAppValue(key, finder) as? Bool ?? false
    }

    /// Takes effect for Finder windows opened from now on.
    static func show() {
        CFPreferencesSetAppValue(key, kCFBooleanTrue, finder)
        CFPreferencesAppSynchronize(finder)
    }
}

// MARK: - Paths

enum PathResolver {
    static func expand(_ raw: String, relativeTo base: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("file://"), let url = URL(string: text) { text = url.path }
        if text.hasPrefix("~") { text = (text as NSString).expandingTildeInPath }
        if !text.hasPrefix("/") { text = (base.isEmpty ? NSHomeDirectory() : base) + "/" + text }
        return text
    }

    static func existingPath(from raw: String, relativeTo base: String) -> String? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let manager = FileManager.default
        var path = expand(raw, relativeTo: base)
        if !manager.fileExists(atPath: path) {
            // path copied from Terminal: "My\ Folder"
            let unescaped = path.replacingOccurrences(of: "\\", with: "")
            guard manager.fileExists(atPath: unescaped) else { return nil }
            path = unescaped
        }
        return (path as NSString).standardizingPath
    }

    /// Completes the last path component from existing folders.
    static func complete(_ raw: String, relativeTo base: String) -> String? {
        let text = expand(raw, relativeTo: base)
        let directory = text.hasSuffix("/") ? text : (text as NSString).deletingLastPathComponent
        let prefix = text.hasSuffix("/") ? "" : (text as NSString).lastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        let folders = items.filter { name in
            guard name.lowercased().hasPrefix(prefix.lowercased()), prefix.hasPrefix(".") || !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        guard let first = folders.first else { return nil }
        if folders.count == 1 { return (directory as NSString).appendingPathComponent(first) + "/" }
        let common = folders.dropFirst().reduce(first) { $0.commonPrefix(with: $1, options: .caseInsensitive) }
        return common.count > prefix.count ? (directory as NSString).appendingPathComponent(common) : nil
    }
}

// MARK: - Web addresses

/// Addresses that are not paths, opened in the browser (or whatever app handles them) like in Windows Explorer.
enum WebAddress {
    /// Bare domains count only with these endings, so a mistyped `notes.txt` is not sent to the web.
    private static let commonDomains = ["com", "org", "net", "eu", "cz", "sk", "de", "at", "io", "info"]

    /// `https://…`, `smb://…`, `mailto:…` and the like. These always win over paths.
    static func explicitURL(from raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemeEnd = text.range(of: "://") ?? (text.lowercased().hasPrefix("mailto:") ? text.range(of: ":") : nil)
        guard let schemeEnd else { return nil }
        let scheme = text[..<schemeEnd.lowerBound]
        guard scheme.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil,
              scheme.lowercased() != "file"
        else { return nil }
        return makeURL(text)
    }

    /// `www.…` or a bare domain such as `seznam.cz`; used only when no such file or folder exists.
    static func looseURL(from raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let domains = commonDomains.joined(separator: "|")
        let isWeb = text.lowercased().hasPrefix("www.") && !text.contains(" ")
            || text.range(of: "^([a-z0-9-]+\\.)+(\(domains))(:[0-9]+)?(/\\S*)?$", options: [.regularExpression, .caseInsensitive]) != nil
        return isWeb ? makeURL("https://" + text) : nil
    }

    private static func makeURL(_ text: String) -> URL? {
        if let url = URL(string: text), url.scheme != nil { return url }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert("#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }
}

// MARK: - The bar

final class BarBackgroundView: NSView {
    /// Bottom corner radii (left, right); non-zero only where the bar sits in a rounded window corner.
    var bottomRadii = NSSize.zero { didSet { needsDisplay = true } }
    var highlight: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let shape = outline(bounds)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        shape.fill()

        let border = outline(bounds.insetBy(dx: highlight == nil ? 0.5 : 1, dy: highlight == nil ? 0.5 : 1))
        border.lineWidth = highlight == nil ? 1 : 2
        (highlight ?? NSColor.separatorColor).setStroke()
        border.stroke()
    }

    private func outline(_ rect: NSRect) -> NSBezierPath {
        let left = bottomRadii.width, right = bottomRadii.height
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + left))
        if left > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.minX + left, y: rect.minY + left), radius: left, startAngle: 180, endAngle: 270)
        }
        path.line(to: NSPoint(x: rect.maxX - right, y: rect.minY))
        if right > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.maxX - right, y: rect.minY + right), radius: right, startAngle: 270, endAngle: 360)
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        (window as? BarPanel)?.requestFocus()
    }
}

final class PathField: NSTextField {
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? BarPanel, panel.deferFocusIfNeeded() { return }
        (window as? BarPanel)?.prepareForEditing()
        super.mouseDown(with: event)
        // the first click selects the whole path, like Windows Explorer
        currentEditor()?.selectAll(nil)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

final class BarPanel: NSPanel, NSTextFieldDelegate, NSWindowDelegate {
    let finderWindowID: Int
    private(set) var path = ""
    var onSubmit: ((BarPanel, String) -> Void)?
    /// Returns true when the Finder window has to come forward first and focus follows later.
    var onFocusRequest: ((BarPanel) -> Bool)?
    var onEditingEnded: (() -> Void)?

    private let background = BarBackgroundView()
    private let icon = NSImageView()
    private let field = PathField()

    init(finderWindowID: Int) {
        self.finderWindowID = finderWindowID
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 28),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .normal
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        delegate = self

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.placeholderString = L10n.text("Type a path…", "Zadejte cestu…")
        // otherwise AppKit focuses the field as soon as the panel shows and the path stops updating
        field.refusesFirstResponder = true
        field.delegate = self
        field.onFocus = { [weak self] in self?.background.highlight = .controlAccentColor }
        icon.imageScaling = .scaleProportionallyDown

        contentView = background
        for view in [icon, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
    }

    // The panel takes the keyboard only while typing; otherwise AppKit would hand it to another bar instead of Finder.
    private var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }

    override var canBecomeMain: Bool { false }

    func prepareForEditing() {
        acceptsKey = true
        field.refusesFirstResponder = false
        makeKey()
    }

    var isEditing: Bool { field.currentEditor() != nil }

    var bottomRadii: NSSize {
        get { background.bottomRadii }
        set { if background.bottomRadii != newValue { background.bottomRadii = newValue } }
    }

    func update(path newPath: String) {
        if newPath != path {
            path = newPath
            icon.image = newPath.isEmpty
                ? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                : NSWorkspace.shared.icon(forFile: newPath)
        }
        if !isEditing, field.stringValue != path { field.stringValue = path }
    }

    func requestFocus() {
        if !deferFocusIfNeeded() { beginEditing() }
    }

    func deferFocusIfNeeded() -> Bool { onFocusRequest?(self) ?? false }

    func beginEditing() {
        prepareForEditing()
        makeFirstResponder(field)
    }

    func endEditing(revert: Bool) {
        if revert { field.stringValue = path }
        makeFirstResponder(nil)
        background.highlight = nil
        acceptsKey = false
        if isKeyWindow {
            // ordering out gives the keyboard back to Finder; the controller shows the bar again right away
            orderOut(nil)
            onEditingEnded?()
        }
    }

    func rejectInput() {
        NSSound.beep()
        background.highlight = .systemRed
        after(0.6) { [weak self] in
            guard let self, self.background.highlight == .systemRed else { return }
            self.background.highlight = self.isEditing ? .controlAccentColor : nil
        }
    }

    // There is no Edit menu, so clipboard shortcuts have to be forwarded by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers {
            let action: Selector? = switch key {
            case "x": #selector(NSText.cut(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": Selector(("undo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(self, textView.string)
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(revert: true)
        case #selector(NSResponder.insertTab(_:)):
            if let completed = PathResolver.complete(textView.string, relativeTo: path) {
                textView.string = completed
                textView.setSelectedRange(NSRange(location: (completed as NSString).length, length: 0))
            } else {
                NSSound.beep()
            }
        case #selector(NSResponder.insertBacktab(_:)):
            break
        default:
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        field.refusesFirstResponder = true
        background.highlight = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        acceptsKey = false
        guard isEditing else { return }
        field.stringValue = path
        makeFirstResponder(nil)
    }
}

// MARK: - Tracking Finder windows

@MainActor
final class Controller: NSObject {
    private let bridge = FinderBridge()
    private var windows: [Int: FinderWindow] = [:]
    private var frontWindowID: Int?
    private var bars: [Int: BarPanel] = [:]
    private var finderPID: pid_t?
    private var polling = false
    private var lastPoll = Date.distantPast
    private var lastMove = Date.distantPast
    private var tickGeneration = 0

    private(set) var notAuthorized = false

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            // a click changes window order, a mouse-up often changes the folder shown
            self?.kick()
            if event.type == .leftMouseUp { after(0.1) { self?.poll() } }
        }
        tick()
    }

    func refresh() { kick() }

    /// `defaults write local.finderpathbar debug -bool true` logs what the tracking does.
    private func debug(_ message: @autoclosure () -> String) {
        if UserDefaults.standard.bool(forKey: "debug") { NSLog("FinderPathBar: \(message())") }
    }

    @objc private func activeApplicationChanged() {
        poll()
        kick()
    }

    private var finderIsFrontmost: Bool {
        finderPID != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == finderPID
    }

    private func kick() {
        lastMove = Date()
        tick()
    }

    private func tick() {
        let front = finderIsFrontmost
        if Date().timeIntervalSince(lastPoll) >= (front ? 0.35 : 1.5) { poll() }
        layout()
        let busy = (front && NSEvent.pressedMouseButtons != 0) || Date().timeIntervalSince(lastMove) < 0.6
        tickGeneration += 1
        let generation = tickGeneration
        after(busy ? 1.0 / 60 : (front ? 1.0 / 15 : 0.25)) { [weak self] in
            guard let self, self.tickGeneration == generation else { return }
            self.tick()
        }
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        lastPoll = Date()
        finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        bridge.listWindows { [weak self] result in
            guard let self else { return }
            self.polling = false
            switch result {
            case .success(let list):
                self.notAuthorized = false
                self.apply(list)
            case .failure(.notAuthorized):
                if !self.notAuthorized { NSLog("FinderPathBar: not allowed to control Finder") }
                self.notAuthorized = true
                self.windows = [:]
            case .failure(let error):
                NSLog("FinderPathBar: listing windows failed: \(error)")
            }
            self.layout()
        }
    }

    private func apply(_ list: [FinderWindow]) {
        let onScreen = Set(onScreenWindows().map(\.id))
        var updated: [Int: FinderWindow] = [:]
        for var window in list where !window.collapsed {
            // background tabs are separate windows with the same frame that are not on screen
            window.hasSeveralTabs = list.contains {
                $0.id != window.id && !$0.collapsed && $0.bounds == window.bounds && !onScreen.contains($0.id)
            }
            updated[window.id] = window
            if let old = windows[window.id], old.path != window.path { debug("path \(window.id): '\(old.path)' -> '\(window.path)'") }
        }
        for id in windows.keys where updated[id] == nil { debug("window \(id) missing from poll") }
        windows = updated
        frontWindowID = list.first?.id
    }

    private struct ScreenWindow {
        let id: Int
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    private static let raisedLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// On-screen windows, front to back.
    private func onScreenWindows() -> [ScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return ScreenWindow(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
        }
    }

    private func layout() {
        var shown = Set<Int>()
        if let finderPID, !windows.isEmpty {
            let entries = onScreenWindows()
            for (index, entry) in entries.enumerated() where entry.pid == finderPID && entry.layer == 0 {
                guard let window = windows[entry.id], let rect = barRect(for: window, bounds: entry.bounds) else { continue }
                shown.insert(entry.id)
                let bar = bar(for: entry.id)
                bar.update(path: window.path)
                bar.bottomRadii = bottomRadii(for: window)
                let frame = appKitFrame(rect)
                if bar.frame != frame {
                    bar.setFrame(frame, display: true)
                    lastMove = Date()
                }

                // A click raises the Finder window above everything on its level, the bar included, and what is
                // under the bar would flash through. So while no other window covers the bar's spot, the bar
                // floats one level higher; otherwise it sits right above its own window.
                let covered = entries[..<index].contains {
                    $0.layer == 0 && $0.pid != ownPID && $0.alpha > 0 && $0.bounds.intersects(rect)
                }
                let level = covered ? NSWindow.Level.normal : Self.raisedLevel
                let levelChanged = bar.level != level
                if levelChanged { bar.level = level }
                if covered {
                    if levelChanged || !bar.isVisible || !isAttached(bar, toEntryAt: index, in: entries) {
                        debug("reorder bar of \(entry.id), visible=\(bar.isVisible)")
                        bar.order(.above, relativeTo: entry.id)
                    }
                } else if !bar.isVisible {
                    bar.orderFront(nil)
                }
            }
        }
        for (id, bar) in bars where !shown.contains(id) {
            if bar.isVisible { debug("hide bar of \(id), known=\(windows[id] != nil)") }
            bar.orderOut(nil)
            if windows[id] == nil { bars[id] = nil }
        }
    }

    /// The bar belongs right above its window; only Finder's helper windows (dialogs etc.) may sit in between.
    private func isAttached(_ bar: BarPanel, toEntryAt index: Int, in entries: [ScreenWindow]) -> Bool {
        for entry in entries[..<index].reversed() {
            if entry.id == bar.windowNumber { return true }
            if entry.pid != finderPID || windows[entry.id] != nil { return false }
        }
        return false
    }

    private func contentInset(for window: FinderWindow) -> CGFloat {
        window.toolbarVisible && window.sidebarWidth > 0 ? window.sidebarWidth + Prefs.metric("sidebarGap") : 0
    }

    /// With several tabs Finder's tab strip takes the row under the toolbar, so the bar moves to the bottom.
    private func placement(for window: FinderWindow) -> Placement {
        window.hasSeveralTabs ? .bottom : Prefs.placement
    }

    /// At the bottom the bar reaches into the window's rounded corners unless the status bar is below it.
    private func bottomRadii(for window: FinderWindow) -> NSSize {
        guard placement(for: window) == .bottom, !window.statusBarVisible else { return .zero }
        let radius = Prefs.metric("windowCornerRadius")
        return NSSize(width: contentInset(for: window) == 0 ? radius : 0, height: radius)
    }

    /// Where the bar goes, in window server coordinates (origin at the top left of the main screen).
    private func barRect(for window: FinderWindow, bounds: CGRect) -> CGRect? {
        let placement = placement(for: window)
        let height = Prefs.metric(placement == .top ? "barHeight" : "pathBarHeight")
        let left = contentInset(for: window)
        let width = bounds.width - left
        guard width >= 160, bounds.height >= 160 else { return nil }

        var top: CGFloat
        switch placement {
        case .top:
            top = bounds.minY + Prefs.metric(window.toolbarVisible ? "toolbarHeight" : "titlebarHeight")
        case .bottom:
            top = bounds.maxY - height
            if window.statusBarVisible { top -= Prefs.metric("statusBarHeight") }
        }
        return CGRect(x: bounds.minX + left, y: top + Prefs.offset, width: width, height: height)
    }

    /// AppKit counts from the bottom of the main screen.
    private func appKitFrame(_ rect: CGRect) -> NSRect {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func bar(for id: Int) -> BarPanel {
        if let bar = bars[id] { return bar }
        let bar = BarPanel(finderWindowID: id)
        bar.onSubmit = { [weak self] bar, text in self?.submit(text, from: bar) }
        bar.onEditingEnded = { [weak self] in self?.layout() }
        bar.onFocusRequest = { [weak self] bar in
            guard let self, !(self.finderIsFrontmost && self.frontWindowID == bar.finderWindowID) else { return false }
            self.bridge.raise(windowID: bar.finderWindowID) { _ in
                self.frontWindowID = bar.finderWindowID
                self.kick()
                // Finder activates with a delay and would take the keyboard back from the bar
                after(0.15) { bar.beginEditing() }
            }
            return true
        }
        bars[id] = bar
        return bar
    }

    private func submit(_ text: String, from bar: BarPanel) {
        if let url = WebAddress.explicitURL(from: text) {
            open(url, from: bar)
            return
        }
        guard let path = PathResolver.existingPath(from: text, relativeTo: bar.path) else {
            if let url = WebAddress.looseURL(from: text) { open(url, from: bar) } else { bar.rejectInput() }
            return
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        // files, apps and document packages open in their app, like in Windows Explorer
        guard isDirectory.boolValue, !NSWorkspace.shared.isFilePackage(atPath: path) else {
            open(URL(fileURLWithPath: path), from: bar)
            return
        }

        bar.endEditing(revert: false)
        bar.update(path: path)
        bridge.show(folder: path, inWindow: bar.finderWindowID) { [weak self] ok in
            if !ok { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            self?.poll()
        }
    }

    private func open(_ url: URL, from bar: BarPanel) {
        bar.endEditing(revert: true)
        if !NSWorkspace.shared.open(url) { NSSound.beep() }
    }

    var isEditing: Bool { bars.values.contains { $0.isEditing } }
}

// MARK: - Updates

enum UpdateError: Error {
    case noRelease, download, invalid, notWritable
    case tool(String)
}

/// Keeps the app current from this project's GitHub releases: download, check, swap the bundle, relaunch.
@MainActor
final class Updater {
    private static let latestRelease = URL(string: "https://github.com/Thominho/finder-address-bar/releases/latest")!
    private static let downloadFormat = "https://github.com/Thominho/finder-address-bar/releases/download/%@/FinderPathBar.zip"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// False while the user is typing in a bar; the relaunch then waits.
    var canRestart: () -> Bool = { true }
    private var busy = false
    private var timer: Timer?

    func start() {
        after(10) { [weak self] in self?.checkAutomatically() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomatically() }
        }
    }

    private func checkAutomatically() {
        if Prefs.autoUpdate { check(manually: false) }
    }

    /// A manual check reports its result; an automatic one stays quiet.
    func check(manually: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let tag = try await Self.latestTag()
                guard Self.isNewer(tag, than: Self.currentVersion) else {
                    if manually {
                        inform(L10n.text("You have the latest version (\(Self.currentVersion)).", "Máte nejnovější verzi (\(Self.currentVersion))."))
                    }
                    return
                }
                let app = try await Self.download(tag: tag)
                try Self.replaceRunningApp(with: app)
                NSLog("FinderPathBar: updated to \(tag)")
                if manually {
                    inform(L10n.text("Updated to \(tag). The app will restart.", "Aktualizováno na \(tag). Aplikace se znovu spustí."))
                }
                restartWhenIdle()
            } catch {
                NSLog("FinderPathBar: update failed: \(error)")
                if manually {
                    inform(L10n.text("Could not update (\(error)).", "Aktualizace se nepovedla (\(error))."))
                }
            }
        }
    }

    /// `releases/latest` redirects to `releases/tag/<tag>`.
    private static func latestTag() async throws -> String {
        var request = URLRequest(url: latestRelease)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let url = response.url, url.path.contains("/releases/tag/") else { throw UpdateError.noRelease }
        return url.lastPathComponent
    }

    static func isNewer(_ candidate: String, than version: String) -> Bool {
        func numbers(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = numbers(candidate), b = numbers(version)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func download(tag: String) async throws -> URL {
        guard let url = URL(string: String(format: downloadFormat, tag)) else { throw UpdateError.download }
        let (zip, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FinderPathBar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        try? FileManager.default.removeItem(at: zip)

        // it has to be this app, in the announced version, with an intact signature
        let app = folder.appendingPathComponent("FinderPathBar.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !isNewer(tag, than: version), !isNewer(version, than: tag)
        else { throw UpdateError.invalid }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private static func replaceRunningApp(with app: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else { throw UpdateError.notWritable }
        _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.tool(tool) }
    }

    private func restartWhenIdle() {
        guard canRestart() else {
            after(5) { [weak self] in self?.restartWhenIdle() }
            return
        }
        // a small shell outlives this process and opens the new copy once this one is gone
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private func inform(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private let updater = Updater()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // a second copy (say, one in Applications and one in Downloads) would draw every bar twice
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if copies.contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
        Prefs.registerDefaults()
        offerSetupIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: L10n.text("Finder Address Bar", "Adresní řádek Finderu"))
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.start()
        updater.canRestart = { [weak self] in !(self?.controller.isEditing ?? false) }
        updater.start()
    }

    /// Asked once, on first launch, before macOS shows its own prompt about controlling Finder.
    private func offerSetupIfNeeded() {
        let defaults = UserDefaults.standard
        let askRow = !defaults.bool(forKey: "didOfferRowSetup") && !FinderTabBar.isShown
        let askLogin = !defaults.bool(forKey: "didOfferLoginItem") && SMAppService.mainApp.status != .enabled
        defaults.set(true, forKey: "didOfferRowSetup")
        defaults.set(true, forKey: "didOfferLoginItem")
        guard askRow || askLogin else { return }

        var explanation: [String] = []
        if askRow {
            explanation.append(L10n.text(
                "Finder can keep an empty row under its toolbar (its tab bar). The address bar then sits on that row and covers nothing.",
                "Finder umí pod panelem nástrojů držet prázdný řádek (řádek panelů). Adresní řádek pak leží na něm a nic nezakrývá."))
        }
        if askLogin {
            explanation.append(L10n.text(
                "Without starting at login, the bar disappears after a restart until you open the app again.",
                "Bez spouštění po přihlášení řádek po restartu zmizí, dokud aplikaci znovu neotevřete."))
        }

        let rowBox = NSButton(checkboxWithTitle: L10n.text("Reserve a row in Finder", "Vyhradit ve Finderu řádek"), target: nil, action: nil)
        let loginBox = NSButton(checkboxWithTitle: L10n.text("Start at login", "Spouštět po přihlášení"), target: nil, action: nil)
        rowBox.state = .on
        loginBox.state = .on
        let boxes = NSStackView(views: (askRow ? [rowBox] : []) + (askLogin ? [loginBox] : []))
        boxes.orientation = .vertical
        boxes.alignment = .leading
        boxes.setFrameSize(boxes.fittingSize)

        let alert = NSAlert()
        alert.messageText = L10n.text("Set up Finder Address Bar", "Nastavení adresního řádku Finderu")
        alert.informativeText = explanation.joined(separator: "\n\n")
        alert.accessoryView = boxes
        alert.addButton(withTitle: L10n.text("Continue", "Pokračovat"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        if askLogin, loginBox.state == .on {
            do { try SMAppService.mainApp.register() } catch { NSLog("FinderPathBar: could not add the login item: \(error)") }
        }
        if askRow, rowBox.state == .on {
            FinderTabBar.show()
            let done = NSAlert()
            done.messageText = L10n.text("New Finder windows now have the row", "Nová okna Finderu už řádek mají")
            done.informativeText = L10n.text(
                "In windows that are already open, choose View → Show Tab Bar.",
                "V oknech, která už jsou otevřená, zvolte Zobrazení → Zobrazit řádek panelů.")
            done.runModal()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if controller.notAuthorized {
            add(L10n.text("Not allowed to control Finder – open Settings…", "Chybí oprávnění ovládat Finder – otevřít Nastavení…"), #selector(openAutomationSettings), to: menu)
            menu.addItem(.separator())
        }
        add(L10n.text("Below the Toolbar", "Pod panelem nástrojů"), #selector(placeTop), to: menu).state = Prefs.placement == .top ? .on : .off
        add(L10n.text("At the Bottom, over the Path Bar", "Dole místo řádku cesty"), #selector(placeBottom), to: menu).state = Prefs.placement == .bottom ? .on : .off
        menu.addItem(.separator())
        add(L10n.text("Move Up 1 pt", "Posunout o bod výš"), #selector(moveUp), to: menu)
        add(L10n.text("Move Down 1 pt", "Posunout o bod níž"), #selector(moveDown), to: menu)
        if Prefs.offset != 0 {
            add(L10n.text("Reset Offset", "Zrušit posun") + " (\(Int(Prefs.offset)))", #selector(resetOffset), to: menu)
        }
        menu.addItem(.separator())
        add(L10n.text("Launch at Login", "Spouštět po přihlášení"), #selector(toggleLoginItem), to: menu).state = SMAppService.mainApp.status == .enabled ? .on : .off
        add(L10n.text("Update Automatically", "Automaticky aktualizovat"), #selector(toggleAutoUpdate), to: menu).state = Prefs.autoUpdate ? .on : .off
        add(L10n.text("Check for Updates…", "Zkontrolovat aktualizace…") + " (\(Updater.currentVersion))", #selector(checkForUpdates), to: menu)
        menu.addItem(.separator())
        add(L10n.text("Quit", "Ukončit"), #selector(quit), to: menu)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func placeTop() { Prefs.placement = .top; controller.refresh() }
    @objc private func placeBottom() { Prefs.placement = .bottom; controller.refresh() }
    @objc private func moveUp() { Prefs.offset -= 1; controller.refresh() }
    @objc private func moveDown() { Prefs.offset += 1; controller.refresh() }
    @objc private func resetOffset() { Prefs.offset = 0; controller.refresh() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("FinderPathBar: could not change the login item: \(error)")
            NSSound.beep()
        }
    }

    @objc private func toggleAutoUpdate() { Prefs.autoUpdate.toggle() }
    @objc private func checkForUpdates() { updater.check(manually: true) }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
