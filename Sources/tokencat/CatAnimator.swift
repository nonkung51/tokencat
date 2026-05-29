import AppKit

/// Maps the token burn rate to an animation speed and drives the frame cycling
/// (SPEC §5). Runs entirely on the main run loop.
final class CatAnimator {
    // Tuning constants — see SPEC §5/§10. Tweak freely.
    // These map the LIVE rate (Δ input+output per minute), which is ~0 when idle
    // and roughly 5k–50k/min during active generation — not ccusage's flat ~4k
    // block average.
    private let rMin = 500.0          // slow-trot floor (tok/min)
    private let rMax = 50_000.0       // full-sprint cap (tok/min)
    private let fpsMin = 3.0
    private let fpsMax = 18.0
    private let idleThreshold = 200.0 // tok/min at or below which we consider idle
    private let coastSeconds = 30.0   // keep running this long after the rate drops

    /// Emits (image, fallbackEmoji) for the current frame; image is nil only if
    /// sprite files are missing.
    var onFrame: ((NSImage?, String) -> Void)?

    private let runFrames: [NSImage]
    private let sleepFrames: [NSImage]

    private enum State: Equatable { case running(fps: Double), sleeping }
    private var state: State = .sleeping
    private var frameIndex = 0
    private var timer: Timer?
    private var lastAboveIdle = Date.distantPast

    init(runFrames: [NSImage], sleepFrames: [NSImage]) {
        self.runFrames = runFrames
        self.sleepFrames = sleepFrames
    }

    func start() { restartTimer() }

    /// Feed the latest indicator burn rate. `hasActiveBlock` is false when there
    /// is no active Claude billing block at all.
    func update(rate: Double?, hasActiveBlock: Bool) {
        let now = Date()
        let r = rate ?? 0
        let active = hasActiveBlock && r > idleThreshold
        if active { lastAboveIdle = now }
        let coasting = hasActiveBlock && now.timeIntervalSince(lastAboveIdle) <= coastSeconds

        apply(active || coasting ? .running(fps: fps(for: r)) : .sleeping)
    }

    // MARK: - Internals

    private func fps(for rate: Double) -> Double {
        let r = max(rate, rMin)
        let x = min(max((log10(r) - log10(rMin)) / (log10(rMax) - log10(rMin)), 0), 1)
        return fpsMin + x * (fpsMax - fpsMin)
    }

    private func isRunning(_ s: State) -> Bool {
        if case .running = s { return true }
        return false
    }

    private func apply(_ newState: State) {
        guard newState != state else { return }
        let modeChanged = isRunning(newState) != isRunning(state)
        state = newState
        if modeChanged { frameIndex = 0 }   // reset gait only when switching run<->sleep
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        emitCurrentFrame()

        // While sleeping we show a single static frame and run NO timer at all.
        // A menu-bar app that ticks ~once a second around the clock keeps the CPU
        // awake and blocks App Nap — by far the worst battery offender here. The
        // cat only animates when there's actually token activity to reflect.
        guard case .running(let fps) = state else { return }

        let interval = 1.0 / max(fps, 0.1)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var tickCount = 0
    private func tick() {
        frameIndex &+= 1
        tickCount &+= 1
        if tickCount % 20 == 0, ProcessInfo.processInfo.environment["TOKENCAT_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[anim] alive: ticks=\(tickCount) state=\(state)\n".utf8))
        }
        emitCurrentFrame()
    }

    private func emitCurrentFrame() {
        let frames: [NSImage]
        let fallback: [String]
        switch state {
        case .running: frames = runFrames;   fallback = Sprites.runFallback
        case .sleeping: frames = sleepFrames; fallback = Sprites.sleepFallback
        }
        let image = frames.isEmpty ? nil : frames[frameIndex % frames.count]
        let emoji = fallback.isEmpty ? "🐱" : fallback[frameIndex % fallback.count]
        onFrame?(image, emoji)
    }
}
