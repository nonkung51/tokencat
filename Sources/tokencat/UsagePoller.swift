import Foundation

struct AgentUsage {
    let name: String
    let tokens: Double
    let cost: Double
}

/// Snapshot of what `ccusage` told us, published to the UI (SPEC §4).
struct UsageSnapshot {
    enum State: Equatable {
        case loading
        case idle
        case running
        case error(String)
    }
    var state: State = .loading
    var tokensPerMin: Double = 0       // LIVE rate: Δ(input+output) since last poll, per minute
    var blockAvgPerMin: Double = 0     // ccusage burnRate.tokensPerMinuteForIndicator (block average)
    var costPerHour: Double = 0
    var blockCost: Double = 0
    var projectedBlockCost: Double = 0
    var blockStart: Date?
    var agents: [AgentUsage] = []
}

/// Polls `ccusage` on a background queue and publishes `UsageSnapshot`s on the
/// main queue (SPEC §7). Parses stdout only; stderr is discarded.
final class UsagePoller {
    private(set) var interval: TimeInterval
    var onUpdate: ((UsageSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "tokencat.poller")
    private var timer: DispatchSourceTimer?
    private var hasFetchedOnline = false

    /// A resolved launch target: the absolute executable plus any fixed arg
    /// prefix (e.g. `bunx ccusage`). Resolved once so we never pay for a login
    /// shell per poll.
    private struct Launcher { let executable: String; let argPrefix: [String] }
    private var cachedLauncher: Launcher?

    /// The `daily` per-agent totals barely move and only show in the menu, so we
    /// refresh them far less often than the live block (which drives the cat).
    private let agentRefreshInterval: TimeInterval = 300
    private var lastAgentRefresh: Date?
    private var cachedAgents: [AgentUsage] = []

    /// When there's no active session we don't need to poll often. Back the
    /// timer off to this while idle and snap back to `interval` once active.
    private let idleInterval: TimeInterval = 60
    private var scheduledInterval: TimeInterval = 0

    // Rolling-window samples of cumulative (input+output) for the live rate.
    private struct Sample { let time: Date; let fresh: Double; let blockStart: Date? }
    private var samples: [Sample] = []
    private let rateWindow: TimeInterval = 60   // seconds — smooths per-turn burstiness

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(interval: TimeInterval = 15) { self.interval = interval }

    func start() {
        publish(UsageSnapshot(state: .loading))
        schedule()
    }

    func setInterval(_ seconds: TimeInterval) {
        interval = seconds
        schedule()
    }

    // MARK: - Scheduling

    private func schedule() { reschedule(every: interval, fireNow: true) }

    /// (Re)arm the timer at a given cadence. Generous leeway lets the OS coalesce
    /// our wakeups with others, which is much kinder to the battery.
    private func reschedule(every seconds: TimeInterval, fireNow: Bool) {
        guard scheduledInterval != seconds || fireNow else { return }
        scheduledInterval = seconds
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let deadline: DispatchTime = fireNow ? .now() : .now() + seconds
        t.schedule(deadline: deadline, repeating: seconds, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func publish(_ snapshot: UsageSnapshot) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
    }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["TOKENCAT_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("[poller] \(message)\n".utf8))
    }

    // MARK: - Polling

    private func poll() {
        guard let launcher = resolveLauncher() else {
            publish(UsageSnapshot(state: .error("ccusage unavailable")))
            return
        }
        let offlineArgs = hasFetchedOnline ? ["-O"] : []

        guard let blocksJSON = run(launcher, ["blocks", "--active", "--json"] + offlineArgs),
              let block = parseActiveBlock(blocksJSON) else {
            publish(UsageSnapshot(state: .error("ccusage unavailable")))
            return
        }
        hasFetchedOnline = true

        var snap = UsageSnapshot()
        snap.state = block.active ? .running : .idle
        snap.blockAvgPerMin = block.blockAvg
        snap.tokensPerMin = liveRate(for: block)
        snap.costPerHour = block.costPerHour
        snap.blockCost = block.blockCost
        snap.projectedBlockCost = block.projected
        snap.blockStart = block.start
        debugLog("live=\(Int(snap.tokensPerMin))/min blockAvg=\(Int(block.blockAvg))/min fresh=\(Int(block.freshTokens))")

        snap.agents = refreshAgentsIfDue(launcher, offlineArgs)

        publish(snap)

        // Idle sessions don't need frequent polling; back off to save battery and
        // snap back to the configured cadence the moment a block goes active.
        reschedule(every: block.active ? interval : max(interval, idleInterval), fireNow: false)
    }

    /// Per-agent daily totals change slowly and are only shown in the menu, so we
    /// recompute them at most every `agentRefreshInterval`, reusing the cache
    /// otherwise. This avoids spawning two extra `ccusage` processes every poll.
    private func refreshAgentsIfDue(_ launcher: Launcher, _ offlineArgs: [String]) -> [AgentUsage] {
        let now = Date()
        if let last = lastAgentRefresh, now.timeIntervalSince(last) < agentRefreshInterval {
            return cachedAgents
        }

        var agents: [AgentUsage] = []
        for (name, sub) in [("Claude", "claude"), ("Codex", "codex")] {
            let json = run(launcher, [sub, "daily", "--json"] + offlineArgs)
            let parsed = json.flatMap(parseDailyToday)
            debugLog("\(sub) daily: bytes=\(json?.count ?? -1) parsed=\(parsed != nil)")
            if let today = parsed {
                agents.append(AgentUsage(name: name, tokens: today.tokens, cost: today.cost))
            }
        }
        cachedAgents = agents
        lastAgentRefresh = now
        return agents
    }

    /// Self-computed recent burn rate, per minute. ccusage's own indicator is a
    /// block-long average that's too smooth to feel live, so we differentiate the
    /// cumulative `input+output` ourselves — but over a rolling window, not a
    /// single poll. Token logging is bursty (per assistant turn), so a one-interval
    /// delta flickers to 0 between turns; a ~60s window keeps the rate alive during
    /// activity and lets it decay smoothly when you actually stop.
    private func liveRate(for block: ActiveBlock) -> Double {
        guard block.active else { samples.removeAll(); return 0 }
        let now = Date()

        // Drop history if the block rolled over or counts reset (new block / restart).
        if let last = samples.last,
           last.blockStart != block.start || block.freshTokens < last.fresh {
            samples.removeAll()
        }
        samples.append(Sample(time: now, fresh: block.freshTokens, blockStart: block.start))

        // Keep samples within the window, but always retain at least two so we can
        // still compute a rate right after a reset.
        let cutoff = now.addingTimeInterval(-rateWindow)
        while samples.count > 2, let first = samples.first, first.time < cutoff {
            samples.removeFirst()
        }

        guard samples.count >= 2, let first = samples.first else { return 0 }
        let minutes = max(now.timeIntervalSince(first.time) / 60.0, 1.0 / 60.0)
        return (block.freshTokens - first.fresh) / minutes
    }

    /// Resolve, exactly once, the absolute path to either `ccusage` or `bunx`.
    /// The one-time probe pays for a login shell so we pick up the user's PATH;
    /// every subsequent poll then execs the resolved binary directly, with no
    /// shell at all — the original code re-sourced `.zshrc` on every call.
    private func resolveLauncher() -> Launcher? {
        if let cached = cachedLauncher { return cached }
        if let ccusage = which("ccusage") {
            cachedLauncher = Launcher(executable: ccusage, argPrefix: [])
        } else if let bunx = which("bunx") {
            cachedLauncher = Launcher(executable: bunx, argPrefix: ["ccusage"])
        }
        return cachedLauncher
    }

    /// One-time absolute-path lookup via a login shell (so user PATH is honored).
    private func which(_ tool: String) -> String? {
        guard let path = runShell("command -v \(tool)")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return path
    }

    /// Exec the resolved launcher directly — no shell per call.
    private func run(_ launcher: Launcher, _ args: [String]) -> String? {
        return launch(URL(fileURLWithPath: launcher.executable), launcher.argPrefix + args)
    }

    /// Run a command in a login shell, returning stdout (stderr → /dev/null).
    /// Used only for the one-time PATH probe.
    private func runShell(_ command: String) -> String? {
        return launch(URL(fileURLWithPath: "/bin/zsh"), ["-lc", command])
    }

    private func launch(_ executable: URL, _ arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Parsing

    private struct ActiveBlock {
        let active: Bool
        let blockAvg: Double      // ccusage's smoothed block-average indicator
        let freshTokens: Double   // cumulative input+output (basis for the live rate)
        let costPerHour: Double
        let blockCost: Double
        let projected: Double
        let start: Date?
    }

    /// Returns nil only on invalid/missing JSON (treated as an error). An empty
    /// `blocks` array is valid and means "idle".
    private func parseActiveBlock(_ json: String) -> ActiveBlock? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["blocks"] as? [[String: Any]] else { return nil }

        guard let b = blocks.first(where: { ($0["isActive"] as? Bool) == true }) ?? blocks.first else {
            return ActiveBlock(active: false, blockAvg: 0, freshTokens: 0,
                               costPerHour: 0, blockCost: 0, projected: 0, start: nil)
        }

        let burn = b["burnRate"] as? [String: Any]
        let blockAvg = (burn?["tokensPerMinuteForIndicator"] as? NSNumber)?.doubleValue ?? 0
        let cph = (burn?["costPerHour"] as? NSNumber)?.doubleValue ?? 0
        let cost = (b["costUSD"] as? NSNumber)?.doubleValue ?? 0
        let projection = b["projection"] as? [String: Any]
        let projected = (projection?["totalCost"] as? NSNumber)?.doubleValue ?? 0
        let start = (b["startTime"] as? String).flatMap { Self.iso.date(from: $0) }
        let active = ((b["isActive"] as? Bool) ?? false) && burn != nil

        // input+output only — excludes cheap cache reads and bursty cache creation.
        let counts = b["tokenCounts"] as? [String: Any]
        let input = (counts?["inputTokens"] as? NSNumber)?.doubleValue ?? 0
        let output = (counts?["outputTokens"] as? NSNumber)?.doubleValue ?? 0

        return ActiveBlock(active: active, blockAvg: blockAvg, freshTokens: input + output,
                           costPerHour: cph, blockCost: cost, projected: projected, start: start)
    }

    private func parseDailyToday(_ json: String) -> (tokens: Double, cost: Double)? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = obj["daily"] as? [[String: Any]] else { return nil }
        let today = Self.todayString()
        guard let row = daily.last(where: { ($0["date"] as? String) == today }) else { return nil }
        let tokens = (row["totalTokens"] as? NSNumber)?.doubleValue ?? 0
        // Cost key differs by agent: Codex uses `costUSD`, Claude uses `totalCost`.
        let cost = (row["costUSD"] as? NSNumber)?.doubleValue
            ?? (row["totalCost"] as? NSNumber)?.doubleValue
            ?? 0
        return (tokens, cost)
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        // Pin to POSIX/Gregorian so the year matches ccusage's dates even under a
        // non-Gregorian system locale (e.g. the Thai Buddhist calendar → 2569).
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }
}
