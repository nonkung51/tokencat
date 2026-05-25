import AppKit

// TokenCat — a RunCat-style menu-bar app whose cat runs faster the more tokens
// you're burning, read from `ccusage`. See SPEC.md.
//
// Entry point: a plain AppKit app with no Dock icon (.accessory policy).

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
