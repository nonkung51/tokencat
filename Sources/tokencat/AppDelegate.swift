import AppKit

/// Owns the status item and menu; wires the poller → animator → UI (SPEC §4/§6).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var animator: CatAnimator!
    private let poller = UsagePoller(interval: 15)

    private var latest = UsageSnapshot(state: .loading)

    // Current button contents, combined in `refreshButton()`.
    private var currentImage: NSImage?
    private var currentEmoji = "😴"
    private var rateText = "⏳"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        animator = CatAnimator(runFrames: Sprites.run, sleepFrames: Sprites.sleep)
        animator.onFrame = { [weak self] image, emoji in
            self?.currentImage = image
            self?.currentEmoji = emoji
            self?.refreshButton()
        }
        animator.start()

        poller.onUpdate = { [weak self] snapshot in self?.apply(snapshot) }
        poller.start()

        updateMenu()
    }

    // MARK: - Applying snapshots

    private func apply(_ snapshot: UsageSnapshot) {
        latest = snapshot
        if ProcessInfo.processInfo.environment["TOKENCAT_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[tokencat] \(snapshot)\n".utf8))
        }
        switch snapshot.state {
        case .loading:
            rateText = "⏳"
            animator.update(rate: 0, hasActiveBlock: false)
        case .error:
            rateText = "⚠️"
            animator.update(rate: 0, hasActiveBlock: false)
        case .idle:
            rateText = ""
            animator.update(rate: 0, hasActiveBlock: false)
        case .running:
            // Hide the number when resting (live rate ~0) so the bar isn't a
            // permanent "0/m"; the sleeping cat conveys it instead.
            rateText = snapshot.tokensPerMin >= 200 ? Fmt.rate(snapshot.tokensPerMin) : ""
            animator.update(rate: snapshot.tokensPerMin, hasActiveBlock: true)
        }
        refreshButton()
        updateMenu()
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        button.image = currentImage
        if currentImage == nil {
            // No sprite files — fall back to an emoji, then the rate.
            button.title = rateText.isEmpty ? currentEmoji : "\(currentEmoji) \(rateText)"
        } else {
            button.title = rateText.isEmpty ? "" : " \(rateText)"
        }
    }

    // MARK: - Menu

    private func updateMenu() {
        let menu = NSMenu()

        func info(_ text: String) {
            menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: ""))
        }

        switch latest.state {
        case .loading:
            info("⏳ Loading ccusage…")
        case .error(let message):
            info("⚠️ \(message)")
            info("Need `ccusage` on PATH or `bun` installed")
        case .idle:
            info("😴 Idle — no active session")
        case .running:
            info("🔥 Now: \(Fmt.tokens(latest.tokensPerMin)) tok/min")
            info("Block avg: \(Fmt.tokens(latest.blockAvgPerMin)) tok/min")
            info("Cost/hr: \(Fmt.cost(latest.costPerHour))")
            var line = "This block: \(Fmt.cost(latest.blockCost))"
            if let start = latest.blockStart { line += "  (since \(Self.hourMinute(start)))" }
            info(line)
            info("Projected block: \(Fmt.cost(latest.projectedBlockCost))")
        }

        if !latest.agents.isEmpty {
            menu.addItem(.separator())
            info("Today by agent")
            for agent in latest.agents {
                info("  \(agent.name): \(Fmt.tokens(agent.tokens)) tok · \(Fmt.cost(agent.cost))")
            }
        }

        menu.addItem(.separator())
        menu.addItem(refreshMenuItem())

        let quit = NSMenuItem(title: "Quit TokenCat", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func refreshMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Refresh: \(Int(poller.interval))s", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for seconds in [5, 15, 30, 60] {
            let option = NSMenuItem(title: "\(seconds)s", action: #selector(setRefresh(_:)), keyEquivalent: "")
            option.target = self
            option.tag = seconds
            option.state = Int(poller.interval) == seconds ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    @objc private func setRefresh(_ sender: NSMenuItem) {
        poller.setInterval(TimeInterval(sender.tag))
        updateMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func hourMinute(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
