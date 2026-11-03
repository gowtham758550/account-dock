import Foundation

/// The user's regular Claude Desktop profile ("Claude" in Application Support) — the one they're
/// signed in to before using this app. It's only ever read; importing copies it into a new profile.
enum DefaultProfile {
    static let dir = Store.appSupport.appendingPathComponent("Claude")
    static var exists: Bool { FileManager.default.fileExists(atPath: dir.path) }

    /// Big re-downloadable items (Cowork VM image, caches, downloaded Claude Code binaries) are skipped:
    /// ~200 MB is copied instead of many GB. Login, settings and chat data come across.
    private static let skip = [
        "vm_bundles/", "claude-code-vm/", "claude-code/", "Cache/", "Code Cache/", "GPUCache/",
        "GraphiteDawnCache/", "DawnGraphiteCache/", "DawnWebGPUCache/", "Crashpad/",
    ]

    /// Copies the default profile into `dest`. The default profile must be closed first.
    static func copy(to dest: URL) throws {
        var args = ["-a"]
        for s in skip { args += ["--exclude", s] }
        args += [dir.path + "/", dest.path + "/"]
        do {
            try AppBuilder.run("/usr/bin/rsync", args)
        } catch {
            try? FileManager.default.removeItem(at: dest)   // don't leave a half-copied profile behind
            throw error
        }
    }
}
