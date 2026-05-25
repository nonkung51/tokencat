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
    private var cachedBase: String?
    private var hasFetchedOnline = false

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

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
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
        let base = resolveBase()
        let offline = hasFetchedOnline ? " -O" : ""

        guard let blocksJSON = runShell("\(base) blocks --active --json\(offline)"),
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

        var agents: [AgentUsage] = []
        for (name, sub) in [("Claude", "claude"), ("Codex", "codex")] {
            let json = runShell("\(base) \(sub) daily --json\(offline)")
            let parsed = json.flatMap(parseDailyToday)
            debugLog("\(sub) daily: bytes=\(json?.count ?? -1) parsed=\(parsed != nil)")
            if let today = parsed {
                agents.append(AgentUsage(name: name, tokens: today.tokens, cost: today.cost))
            }
        }
        snap.agents = agents

        publish(snap)
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

    /// Use `ccusage` if on PATH, else `bunx ccusage`. Resolved once.
    private func resolveBase() -> String {
        if let base = cachedBase { return base }
        let probe = runShell("command -v ccusage")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (probe?.isEmpty == false) ? "ccusage" : "bunx ccusage"
        cachedBase = base
        return base
    }

    /// Run a command in a login shell, returning stdout (stderr → /dev/null).
    private func runShell(_ command: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
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
