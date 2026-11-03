import AppKit

/// Builds a per-profile copy of Claude.app with its own bundle ID and a badged icon, so each
/// profile gets a separate Dock icon. The original /Applications/Claude.app is only read.
///
/// Why each step exists (all verified by experiment on macOS 27):
///  - the copy needs its OWN bundle ID, or LaunchServices/the Dock treat it as the original;
///  - the icon is declared in Assets.car via CFBundleIconName, which wins over the .icns, so that key is removed;
///  - editing the bundle breaks Anthropic's signature and macOS deletes the app on launch, so it is re-signed ad-hoc;
///  - an ad-hoc signature cannot carry Anthropic's restricted entitlements (SIGKILL at launch), so those are dropped;
///  - Electron finds its helper apps via CFBundleName, so that must NOT be changed.
enum AppBuilder {
    struct BuildError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let original = URL(fileURLWithPath: "/Applications/Claude.app")
    static let appsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")

    private static let restricted: Set<String> = [
        "com.apple.application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups",
    ]

    // MARK: Naming

    /// First letter of each of the first two words: "Work" -> "W", "Side Project" -> "SP".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let s = String(words.prefix(2).compactMap { $0.first }).uppercased()
        return s.isEmpty ? "?" : s
    }

    static func copyURL(for p: Profile) -> URL {
        appsDir.appendingPathComponent("Claude (\(p.name)).app")
    }

    static func bundleID(for p: Profile) -> String { "com.anthropic.claudefordesktop.\(p.id)" }

    // MARK: Staleness

    private static func version(of app: URL) -> String? {
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return plist?["CFBundleVersion"] as? String
    }

    /// True when the copy is missing or was cloned from an older Claude.app.
    static func needsBuild(_ p: Profile) -> Bool {
        let copy = copyURL(for: p)
        guard FileManager.default.fileExists(atPath: copy.path) else { return true }
        guard let want = version(of: original) else { return false }
        return version(of: copy) != want
    }

    // MARK: Build

    static func build(_ p: Profile) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path) else {
            throw BuildError(message: "Claude Desktop isn't installed at /Applications/Claude.app.")
        }
        let copy = copyURL(for: p)
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }

        // APFS clone: near-instant and almost no extra disk.
        try run("/bin/cp", ["-cR", original.path, copy.path])

        do {
            try makeIcon(to: copy.appendingPathComponent("Contents/Resources/electron.icns"),
                         from: original.appendingPathComponent("Contents/Resources/electron.icns"),
                         colorHex: p.color, label: p.badge)

            let plistURL = copy.appendingPathComponent("Contents/Info.plist")
            guard let plist = NSMutableDictionary(contentsOf: plistURL) else {
                throw BuildError(message: "Couldn't read the copy's Info.plist.")
            }
            plist["CFBundleIdentifier"] = bundleID(for: p)
            plist.removeObject(forKey: "CFBundleIconName")
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)

            try resign(copy)
        } catch {
            try? fm.removeItem(at: copy)   // never leave a half-built (and macOS-deletable) copy behind
            throw error
        }

        _ = try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                     ["-f", copy.path])
    }

    // MARK: Signing

    private static func resign(_ app: URL) throws {
        let fm = FileManager.default
        var targets: [String] = []
        if let en = fm.enumerator(atPath: app.path) {
            for case let rel as String in en {
                let full = app.appendingPathComponent(rel).path
                if (try? fm.attributesOfItem(atPath: full))?[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                if [".app", ".framework", ".dylib", ".node", ".so"].contains(where: rel.hasSuffix) { targets.append(full) }
            }
        }
        targets.sort { $0.filter { $0 == "/" }.count > $1.filter { $0 == "/" }.count }   // innermost first
        targets.append(app.path)

        for path in targets {
            var args = ["--force", "--sign", "-", "--timestamp=none"]
            var entFile: URL?
            if path.hasSuffix(".app"), let ents = entitlements(of: path) {
                let f = fm.temporaryDirectory.appendingPathComponent("ent-\(UUID().uuidString).plist")
                try PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0).write(to: f)
                args += ["--entitlements", f.path]
                entFile = f
            }
            defer { if let f = entFile { try? fm.removeItem(at: f) } }
            try run("/usr/bin/codesign", args + [path])
        }
    }

    /// Existing entitlements minus the ones an ad-hoc signature can't hold; nil if none remain.
    private static func entitlements(of path: String) -> [String: Any]? {
        guard let out = try? run("/usr/bin/codesign", ["-d", "--entitlements", ":-", path], captureStdout: true),
              let data = out.data(using: .utf8), !data.isEmpty,
              var dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        restricted.forEach { dict.removeValue(forKey: $0) }
        return dict.isEmpty ? nil : dict
    }

    // MARK: Icon

    /// Original icon + a white-ringed colour disc with initials at the bottom-right, at every size.
    private static func makeIcon(to output: URL, from input: URL, colorHex: String, label: String) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)")
        let inSet = tmp.appendingPathComponent("in.iconset")
        let outSet = tmp.appendingPathComponent("out.iconset")
        try fm.createDirectory(at: outSet, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try run("/usr/bin/iconutil", ["-c", "iconset", input.path, "-o", inSet.path])

        for name in try fm.contentsOfDirectory(atPath: inSet.path) where name.hasSuffix(".png") {
            guard let rep = NSBitmapImageRep(data: try Data(contentsOf: inSet.appendingPathComponent(name))) else { continue }
            let w = rep.pixelsWide, h = rep.pixelsHigh
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: out) else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))

            let d = CGFloat(w) * 0.46, m = CGFloat(w) * 0.04
            let badge = NSRect(x: CGFloat(w) - d - m, y: m, width: d, height: d)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor(hex: colorHex).setFill()
            let disc = badge.insetBy(dx: d * 0.09, dy: d * 0.09)
            NSBezierPath(ovalIn: disc).fill()

            let text = String(label.prefix(2))
            if !text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: disc.height * (text.count == 1 ? 0.62 : 0.46), weight: .heavy),
                    .foregroundColor: NSColor.white,
                ]
                let str = NSAttributedString(string: text, attributes: attrs)
                let ts = str.size()
                str.draw(at: NSPoint(x: disc.midX - ts.width / 2, y: disc.midY - ts.height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()

            try out.representation(using: .png, properties: [:])!.write(to: outSet.appendingPathComponent(name))
        }

        try run("/usr/bin/iconutil", ["-c", "icns", outSet.path, "-o", output.path])
    }

    // MARK: Process helper

    @discardableResult
    static func run(_ tool: String, _ args: [String], captureStdout: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BuildError(message: "\((tool as NSString).lastPathComponent) failed: \(msg.isEmpty ? "exit \(p.terminationStatus)" : msg)")
        }
        return captureStdout ? String(decoding: outData, as: UTF8.self) : ""
    }
}
