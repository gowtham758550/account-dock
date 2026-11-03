import AppKit
import ServiceManagement

// MARK: - Model & storage

struct Profile: Codable, Equatable {
    var id: String
    var name: String
    var color: String      // hex, e.g. "#2F6FEB"
    var dataDir: String    // absolute path passed to Claude as --user-data-dir
    var label: String?     // badge letters; nil/empty = initials of the name
    var imported: Bool?    // true for the profile copied from the user's existing Claude login

    var badge: String {
        let l = (label ?? "").trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? AppBuilder.initials(name) : String(l.uppercased().prefix(2))
    }
}

enum Store {
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    static let dir = appSupport.appendingPathComponent("Account Dock")
    static let file = dir.appendingPathComponent("profiles.json")

    /// No profiles on first run. An unreadable file is left alone rather than overwritten.
    static func load() -> [Profile] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    static func save(_ profiles: [Profile]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profiles) { try? data.write(to: file, options: .atomic) }
    }
}

// MARK: - Claude process control

enum Claude {
    private static let marker = "Contents/MacOS/Claude --user-data-dir="

    /// (pid, full command line) for every process.
    private static func processes() -> [(pid: pid_t, command: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let space = t.firstIndex(of: " "), let pid = pid_t(t[..<space]) else { return nil }
            return (pid, t[t.index(after: space)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// pid of the main Claude process using this data dir, if running.
    static func runningPID(dataDir: String) -> pid_t? {
        for proc in processes() {
            guard let r = proc.command.range(of: marker) else { continue }
            if proc.command[r.upperBound...].trimmingCharacters(in: .whitespaces) == dataDir { return proc.pid }
        }
        return nil
    }

    /// Main process(es) of the user's regular Claude: started with no --user-data-dir argument.
    static func defaultProfilePIDs() -> [pid_t] {
        processes().filter { $0.command.hasSuffix("/Contents/MacOS/Claude") }.map(\.pid)
    }

    /// Brings the profile's window forward if it's running. Returns whether it was.
    static func focusIfRunning(_ profile: Profile) -> Bool {
        guard let pid = runningPID(dataDir: profile.dataDir),
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        app.activate(options: [.activateAllWindows])
        return true
    }

    /// Launches the profile's own badged copy of Claude.app.
    static func open(_ profile: Profile) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", AppBuilder.copyURL(for: profile).path, "--args", "--user-data-dir=\(profile.dataDir)"]
        try? p.run()
    }
}

// MARK: - UI helpers

enum Palette {
    static let presets: [(name: String, hex: String)] = [
        ("Blue", "#2F6FEB"), ("Green", "#2EA66A"), ("Orange", "#F08A24"),
        ("Purple", "#8B5CF6"), ("Red", "#E5484D"), ("Teal", "#14A3A3"), ("Pink", "#E0559B"),
    ]
}

extension NSColor {
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s, radix: 16) ?? 0x888888
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

func dotImage(_ color: NSColor, size: CGFloat = 12) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
        return true
    }
    img.isTemplate = false
    return img
}

func slug(_ s: String) -> String {
    let allowed = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    let joined = String(allowed).split(separator: "-").joined(separator: "-")
    return joined.isEmpty ? "profile" : joined
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var profiles = Store.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Account Dock")
            if button.image == nil { button.title = "CP" }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        DispatchQueue.main.async { self.offerImportOnFirstRun() }
    }

    // Rebuilt every time it opens so running state is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        profiles = Store.load()

        for (i, p) in profiles.enumerated() {
            let running = Claude.runningPID(dataDir: p.dataDir) != nil
            let item = NSMenuItem(title: p.name, action: #selector(openProfile(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.target = self
            item.tag = i
            item.image = dotImage(NSColor(hex: p.color))
            item.state = running ? .on : .off
            if !FileManager.default.fileExists(atPath: p.dataDir) { item.toolTip = "New profile: sign in on first launch" }
            menu.addItem(item)
        }
        if profiles.isEmpty {
            let empty = NSMenuItem(title: "No profiles yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Profile…", action: #selector(addProfile), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)

        if DefaultProfile.exists && !profiles.contains(where: { $0.imported == true }) {
            let imp = NSMenuItem(title: "Import Current Claude Account…", action: #selector(importAction), keyEquivalent: "")
            imp.target = self
            menu.addItem(imp)
        }

        if !profiles.isEmpty {
            let edit = NSMenuItem(title: "Edit Profile", action: nil, keyEquivalent: "")
            let editSub = NSMenu()
            for (i, p) in profiles.enumerated() {
                let it = NSMenuItem(title: p.name, action: #selector(editProfile(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                it.image = dotImage(NSColor(hex: p.color))
                editSub.addItem(it)
            }
            edit.submenu = editSub
            menu.addItem(edit)

            let remove = NSMenuItem(title: "Remove Profile", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, p) in profiles.enumerated() {
                let it = NSMenuItem(title: p.name, action: #selector(removeProfile(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                it.image = dotImage(NSColor(hex: p.color))
                sub.addItem(it)
            }
            remove.submenu = sub
            menu.addItem(remove)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Account Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openProfile(_ sender: NSMenuItem) {
        guard profiles.indices.contains(sender.tag) else { return }
        launch(profiles[sender.tag])
    }

    private var building = Set<String>()

    /// Focus if running; otherwise (re)build the badged copy if needed, then open it.
    private func launch(_ p: Profile) {
        if Claude.focusIfRunning(p) { return }
        guard !building.contains(p.id) else { return }

        // A first launch (no data yet) or a freshly built copy has a code signature macOS hasn't seen, so it
        // asks for Keychain access. Explain that before it happens.
        let needsBuild = AppBuilder.needsBuild(p)
        if needsBuild || !FileManager.default.fileExists(atPath: p.dataDir), !confirmKeychainExplainer() { return }

        guard needsBuild else { Claude.open(p); return }

        building.insert(p.id)
        statusItem.button?.title = " Building \(p.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AppBuilder.build(p) }
            DispatchQueue.main.async {
                self.building.remove(p.id)
                if self.building.isEmpty { self.statusItem.button?.title = "" }
                switch result {
                case .success:
                    Claude.open(p)
                case .failure(let error):
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn't set up “\(p.name)”"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private struct ProfileInput { var name: String; var label: String; var color: String }

    private func showWarning(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }

    /// Name / badge letters / colour form shared by Add and Edit. Re-asks until the input is valid.
    /// `initial` is the profile being edited (nil for Add); its own name doesn't count as a duplicate.
    private func promptProfile(title: String, info: String, confirm: String, cancel: String = "Cancel",
                               initial: Profile?, suggestedName: String = "") -> ProfileInput? {
        var nameValue = initial?.name ?? suggestedName
        var lettersValue = initial?.label ?? ""
        var colorIndex = Palette.presets.firstIndex { $0.hex == initial?.color } ?? 0

        while true {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: cancel)

            let name = NSTextField(frame: NSRect(x: 0, y: 68, width: 260, height: 24))
            name.placeholderString = "Name (e.g. Work)"
            name.stringValue = nameValue
            let letters = NSTextField(frame: NSRect(x: 0, y: 34, width: 260, height: 24))
            letters.placeholderString = "Badge letters (optional — default: initials)"
            letters.stringValue = lettersValue
            let color = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            for c in Palette.presets {
                color.addItem(withTitle: c.name)
                color.lastItem?.image = dotImage(NSColor(hex: c.hex))
            }
            color.selectItem(at: colorIndex)
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 98))
            box.addSubview(name)
            box.addSubview(letters)
            box.addSubview(color)
            alert.accessoryView = box
            alert.window.initialFirstResponder = name

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            nameValue = name.stringValue.trimmingCharacters(in: .whitespaces)
            lettersValue = letters.stringValue.trimmingCharacters(in: .whitespaces)
            colorIndex = color.indexOfSelectedItem

            if nameValue.isEmpty { showWarning("Name is required", "Give the profile a name."); continue }
            if nameValue.contains("/") || nameValue.contains(":") {
                showWarning("Invalid name", "Names can't contain “/” or “:”."); continue
            }
            if profiles.contains(where: { $0.id != initial?.id && $0.name.caseInsensitiveCompare(nameValue) == .orderedSame }) {
                showWarning("Name already used", "Another profile is already called “\(nameValue)”."); continue
            }
            return ProfileInput(name: nameValue, label: lettersValue, color: Palette.presets[colorIndex].hex)
        }
    }

    // MARK: Keychain explainer

    private static let hideKeychainExplainerKey = "hideKeychainExplainer"

    /// Explains the macOS password prompt a new profile triggers, before it appears. Returns false if the
    /// user cancels. "Don't show this again" is remembered (only when they continue).
    private func confirmKeychainExplainer() -> Bool {
        if UserDefaults.standard.bool(forKey: Self.hideKeychainExplainerKey) { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "macOS will ask for your password"
        alert.informativeText = """
            The first time a new profile opens, macOS asks for your Mac login password so the profile can use \
            “Claude Safe Storage” in your Keychain. That's where Claude keeps its sign-in secret, and each \
            profile is its own copy of Claude that macOS hasn't seen before.

            Enter your Mac password and choose “Always Allow” so it doesn't ask again. The prompt comes from \
            macOS itself — Account Dock never sees your password.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: Self.hideKeychainExplainerKey) }
        return true
    }

    // MARK: Import the user's existing Claude login

    private var importing = false

    /// First launch with no profiles: offer to bring the current Claude account in as the first profile (once).
    private func offerImportOnFirstRun() {
        let key = "offeredImportOfDefaultProfile"
        guard profiles.isEmpty, DefaultProfile.exists, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        importDefaultProfile(firstRun: true)
    }

    @objc private func importAction() { importDefaultProfile(firstRun: false) }

    private func importDefaultProfile(firstRun: Bool) {
        guard !importing, DefaultProfile.exists else { return }
        guard let input = promptProfile(
            title: firstRun ? "Welcome — import your Claude account?" : "Import your current Claude account",
            info: "Copies your signed-in Claude Desktop (about 200 MB) into a profile, so you don't have to sign in again. "
                + "Your original Claude is left as it is. It will be closed briefly while copying.",
            confirm: "Import", cancel: firstRun ? "Skip" : "Cancel",
            initial: nil, suggestedName: "Main") else { return }

        let running = Claude.defaultProfilePIDs()
        if !running.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Claude needs to close first"
            a.informativeText = "Your Claude Desktop is open. Save anything in progress — it will be closed now and you can reopen it right after."
            a.addButton(withTitle: "Close Claude & Import")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            running.forEach { NSRunningApplication(processIdentifier: $0)?.terminate() }
        }

        var id = slug(input.name)
        let taken = Set(profiles.map(\.id))
        var n = 2
        let fm = FileManager.default
        func dest(_ id: String) -> URL { Store.appSupport.appendingPathComponent("Claude-\(id)") }
        while taken.contains(id) || fm.fileExists(atPath: dest(id).path) { id = "\(slug(input.name))-\(n)"; n += 1 }

        let profile = Profile(id: id, name: input.name, color: input.color, dataDir: dest(id).path,
                              label: input.label.isEmpty ? nil : input.label, imported: true)

        importing = true
        statusItem.button?.title = " Importing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> Void in
                // Closing is asynchronous: wait for the default profile to actually exit before copying.
                for _ in 0..<30 where !Claude.defaultProfilePIDs().isEmpty { Thread.sleep(forTimeInterval: 0.5) }
                if !Claude.defaultProfilePIDs().isEmpty {
                    throw AppBuilder.BuildError(message: "Claude didn't close. Quit it yourself, then try again.")
                }
                try DefaultProfile.copy(to: URL(fileURLWithPath: profile.dataDir))
            }
            DispatchQueue.main.async {
                self.importing = false
                self.statusItem.button?.title = ""
                switch result {
                case .success:
                    var all = Store.load()
                    all.append(profile)
                    self.profiles = all
                    Store.save(all)
                    self.launch(profile)
                case .failure(let error):
                    self.showWarning("Couldn't import your account", error.localizedDescription)
                }
            }
        }
    }

    @objc private func addProfile() {
        guard let input = promptProfile(
            title: "Add Claude profile",
            info: "Each profile has its own login, chats and settings. You sign in the first time you open it.",
            confirm: "Add & Open", initial: nil) else { return }

        var id = slug(input.name)
        let existing = Set(profiles.map(\.id))
        var n = 2
        while existing.contains(id) { id = "\(slug(input.name))-\(n)"; n += 1 }

        let profile = Profile(id: id, name: input.name, color: input.color,
                              dataDir: Store.appSupport.appendingPathComponent("Claude-\(id)").path,
                              label: input.label)
        profiles.append(profile)
        Store.save(profiles)
        launch(profile)
    }

    @objc private func editProfile(_ sender: NSMenuItem) {
        guard profiles.indices.contains(sender.tag) else { return }
        let old = profiles[sender.tag]

        // The app copy is rebuilt, so the profile can't be running from it.
        if Claude.runningPID(dataDir: old.dataDir) != nil {
            showWarning("“\(old.name)” is still running", "Quit that Claude window first, then edit it again.")
            return
        }
        guard !building.contains(old.id) else { return }

        guard let input = promptProfile(
            title: "Edit “\(old.name)”",
            info: "The icon is rebuilt when you save (about 10–20 seconds). The login and chats are kept.",
            confirm: "Save", initial: old) else { return }

        var new = old
        new.name = input.name
        new.label = input.label.isEmpty ? nil : input.label
        new.color = input.color
        // Nothing visible changed (e.g. letters cleared but the initials are the same): skip the rebuild.
        if new.name == old.name && new.color == old.color && new.badge == old.badge {
            return
        }

        building.insert(old.id)
        statusItem.button?.title = " Updating \(new.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> Void in
                try AppBuilder.build(new)
                // Renamed: the old copy lives at a different path and is now orphaned.
                if AppBuilder.copyURL(for: old) != AppBuilder.copyURL(for: new) {
                    try? FileManager.default.removeItem(at: AppBuilder.copyURL(for: old))
                }
            }
            DispatchQueue.main.async {
                self.building.remove(old.id)
                if self.building.isEmpty { self.statusItem.button?.title = "" }
                switch result {
                case .success:
                    var all = Store.load()
                    if let i = all.firstIndex(where: { $0.id == old.id }) { all[i] = new }
                    self.profiles = all
                    Store.save(all)
                case .failure(let error):
                    self.showWarning("Couldn't update “\(old.name)”", error.localizedDescription)
                }
            }
        }
    }

    @objc private func removeProfile(_ sender: NSMenuItem) {
        guard profiles.indices.contains(sender.tag) else { return }
        let p = profiles[sender.tag]
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(p.name)”?"
        alert.informativeText = "“Remove from list” keeps the login and data on disk. “Move data to Trash” also removes the sign-in and chats for this profile (recoverable from the Trash)."
        alert.addButton(withTitle: "Remove from list")
        alert.addButton(withTitle: "Move data to Trash")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }

        if choice == .alertSecondButtonReturn {
            if Claude.runningPID(dataDir: p.dataDir) != nil {
                let warn = NSAlert()
                warn.messageText = "“\(p.name)” is still running"
                warn.informativeText = "Quit that Claude window first, then remove it again."
                warn.runModal()
                return
            }
            if FileManager.default.fileExists(atPath: p.dataDir) {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p.dataDir), resultingItemURL: nil) }
                catch {
                    let warn = NSAlert(error: error)
                    warn.runModal()
                    return
                }
            }
        }
        // The badged app copy is a regenerable build artifact, so it's removed outright.
        if Claude.runningPID(dataDir: p.dataDir) == nil {
            try? FileManager.default.removeItem(at: AppBuilder.copyURL(for: p))
        }
        profiles.remove(at: sender.tag)
        Store.save(profiles)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
