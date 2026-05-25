import AppKit

/// Loads the cat sprite frames as template `NSImage`s (SPEC §2/§4).
///
/// Assets live at the repo-root `assets/` (generated via Codex `$imagegen`).
/// We resolve that directory at runtime so `swift run` works from the package
/// root; an emoji fallback keeps the app alive if the files are missing.
enum Sprites {
    /// ~18pt-tall menu-bar height for the sprite (3:2 aspect → ~27pt wide).
    private static let targetHeight: CGFloat = 18

    static let run: [NSImage]   = load(folder: "run",   prefix: "run_",   count: 8)
    static let sleep: [NSImage] = load(folder: "sleep", prefix: "sleep_", count: 2)

    /// Emoji frames used only when the PNGs can't be found.
    static let runFallback   = ["🐈", "🐈‍⬛"]
    static let sleepFallback = ["😴"]

    // MARK: - Loading

    private static func load(folder: String, prefix: String, count: Int) -> [NSImage] {
        guard let dir = assetsDir()?.appendingPathComponent(folder, isDirectory: true) else {
            return []
        }
        var frames: [NSImage] = []
        for i in 0..<count {
            let url = dir.appendingPathComponent("\(prefix)\(i).png")
            guard let img = NSImage(contentsOf: url) else { continue }
            img.isTemplate = true
            img.size = scaled(img.size)
            frames.append(img)
        }
        return frames
    }

    private static func scaled(_ size: NSSize) -> NSSize {
        guard size.height > 0 else { return NSSize(width: 27, height: targetHeight) }
        let scale = targetHeight / size.height
        return NSSize(width: (size.width * scale).rounded(), height: targetHeight)
    }

    /// Try, in order: $TOKENCAT_ASSETS, the package root (via #filePath),
    /// the current directory, then next to the executable.
    private static func assetsDir() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["TOKENCAT_ASSETS"] {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        // Bundled .app: assets live in Contents/Resources/assets.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("assets", isDirectory: true))
        }
        // `swift run` dev: #filePath = <root>/Sources/tokencat/Sprites.swift → up 3 → <root>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(root.appendingPathComponent("assets", isDirectory: true))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("assets", isDirectory: true))
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("assets", isDirectory: true))

        let chosen = candidates.first { fm.fileExists(atPath: $0.path) }
        if ProcessInfo.processInfo.environment["TOKENCAT_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[sprites] assets dir = \(chosen?.path ?? "NONE")\n".utf8))
        }
        return chosen
    }
}
