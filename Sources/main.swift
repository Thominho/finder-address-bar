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
            "tabBarHeight": 28.0,
            "statusBarHeight": 28.0,
            "barHeight": 28.0,
            "pathBarHeight": 30.0,
            "windowCornerRadius": 26.0,
            "sidebarGap": 8.0,
            "offset": 0.0,
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
    var hasTabBar = false
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

    /// Points the window at a folder; for a file, at its parent folder with the file selected.
    func show(path: String, isFolder: Bool, inWindow id: Int, _ completion: @escaping @MainActor (Bool) -> Void) {
        let source: String
        if isFolder {
            source = """
                set f to (POSIX file "\(Self.quoted(path))") as alias
                tell application "Finder" to set target of Finder window id \(id) to f
                """
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            source = """
                set f to (POSIX file "\(Self.quoted(path))") as alias
                set d to (POSIX file "\(Self.quoted(parent))") as alias
                tell application "Finder"
                	set target of Finder window id \(id) to d
                	reveal f
                end tell
                """
        }
        execute(source, completion)
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
            window.hasTabBar = list.contains {
                $0.id != window.id && !$0.collapsed && $0.bounds == window.bounds && !onScreen.contains($0.id)
            }
            updated[window.id] = window
        }
        windows = updated
        frontWindowID = list.first?.id
    }

    private struct ScreenWindow {
        let id: Int
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    /// On-screen windows, front to back.
    private func onScreenWindows() -> [ScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return ScreenWindow(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }

    private func layout() {
        var shown = Set<Int>()
        if let finderPID, !windows.isEmpty {
            let entries = onScreenWindows()
            for (index, entry) in entries.enumerated() where entry.pid == finderPID && entry.layer == 0 {
                guard let window = windows[entry.id], let frame = barFrame(for: window, bounds: entry.bounds) else { continue }
                shown.insert(entry.id)
                let bar = bar(for: entry.id)
                bar.update(path: window.path)
                bar.bottomRadii = bottomRadii(for: window)
                if bar.frame != frame {
                    bar.setFrame(frame, display: true)
                    lastMove = Date()
                }
                if !bar.isVisible || !isAttached(bar, toEntryAt: index, in: entries) {
                    bar.order(.above, relativeTo: entry.id)
                }
            }
        }
        for (id, bar) in bars where !shown.contains(id) {
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

    /// At the bottom the bar reaches into the window's rounded corners unless the status bar is below it.
    private func bottomRadii(for window: FinderWindow) -> NSSize {
        guard Prefs.placement == .bottom, !window.statusBarVisible else { return .zero }
        let radius = Prefs.metric("windowCornerRadius")
        return NSSize(width: contentInset(for: window) == 0 ? radius : 0, height: radius)
    }

    private func barFrame(for window: FinderWindow, bounds: CGRect) -> NSRect? {
        let height = Prefs.metric(Prefs.placement == .top ? "barHeight" : "pathBarHeight")
        let left = contentInset(for: window)
        let width = bounds.width - left
        guard width >= 160, bounds.height >= 160 else { return nil }

        var top: CGFloat
        switch Prefs.placement {
        case .top:
            top = bounds.minY + Prefs.metric(window.toolbarVisible ? "toolbarHeight" : "titlebarHeight")
            if window.hasTabBar { top += Prefs.metric("tabBarHeight") }
        case .bottom:
            top = bounds.maxY - height
            if window.statusBarVisible { top -= Prefs.metric("statusBarHeight") }
        }
        top += Prefs.offset

        // the window server counts from the top, AppKit from the bottom of the main screen
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: bounds.minX + left, y: screenHeight - top - height, width: width, height: height)
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
        guard let path = PathResolver.existingPath(from: text, relativeTo: bar.path) else {
            bar.rejectInput()
            return
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let isFolder = isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path)

        bar.endEditing(revert: false)
        bar.update(path: isFolder ? path : (path as NSString).deletingLastPathComponent)
        bridge.show(path: path, isFolder: isFolder, inWindow: bar.finderWindowID) { [weak self] ok in
            if !ok { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            self?.poll()
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: L10n.text("Finder Address Bar", "Adresní řádek Finderu"))
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.start()
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
