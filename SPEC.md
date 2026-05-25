# TokenCat — Spec

A simple, stupid macOS menu-bar app. Like [RunCat](https://github.com/Kyome22/RunCat_for_macOS), but the cat runs faster the more **tokens** you're burning across your coding agents (Claude Code, Codex, etc.) — read via [`ccusage`](https://github.com/ryoppippi/ccusage).

> One-liner: *"RunCat, but the treadmill is your API bill."*

**Status:** Built, packaged & verified. Phases 0–3 implemented (sprites, running cat + tokens/min, per-agent dropdown, refresh submenu, error/loading states, `--offline`). Phase 4: **packaged as `TokenCat.app`** via `./package.sh` (Info.plist with `LSUIElement`, bundled assets, Codex-generated icon → `.icns`, ad-hoc signed). Run via `swift run` (dev) or `open build/TokenCat.app`. Launch-at-login & spend alerts still deferred. Cat speed is driven by a self-computed **live** burn rate, not ccusage's flat block-average indicator — see §3a.

> Build note: `ccusage` daily dates are Gregorian, so all date formatting pins `en_US_POSIX`/Gregorian — a plain `DateFormatter` under a Thai Buddhist-calendar locale yields year `2569` and silently breaks the today-row match.

---

## 1. Goals & non-goals

**Goals**
- A menu-bar cat whose animation speed reflects your live token **burn rate**.
- Click to see a breakdown of today's usage **per agent** (Claude, Codex, …) with cost.
- Dead simple to run and dead simple to read. No config required to start.

**Non-goals (for now)**
- No historical charts / graphs.
- No notifications/alerts on spend (nice future idea).
- No cross-platform — macOS only.
- No bundled `.app` / notarization in the MVP (run via `swift run`); packaging is a later phase.

---

## 2. Tech stack (decided)

- **Language/UI:** Swift + AppKit, as a **Swift Package Manager executable** (no Xcode project).
  - `NSStatusItem` for the menu-bar item; `NSApp.setActivationPolicy(.accessory)` so there's no Dock icon.
  - Run with `swift run`; build with `swift build -c release`.
- **Visuals (decided):** **Monochrome silhouette PNG sprites from the start**, shown as `NSImage` template images (`image.isTemplate = true`) so they auto-adapt to light/dark menu bars (RunCat-style). The status-bar button shows the **sprite (image) + tokens/min (title)** together.
  - **Sprite source (done):** Codex CLI's `$imagegen` tool generated the set via `codex exec --skip-git-repo-check --sandbox workspace-write`, which also post-processed them in PIL (gutter-detect slice, alpha-trim, bottom-align, binarize). Assets live in `assets/run/` (8 frames) and `assets/sleep/` (2 frames), each **120×80 px**, transparent, binary-black. To regenerate, see the recorded prompt approach in §9.
  - **Display size:** set each `NSImage` to ~**18 pt tall** preserving the 3:2 aspect (~27 pt wide) for the status bar; `isTemplate = true`.
  - **Emoji = fallback only.** If a sprite file is missing/unreadable, fall back to an emoji frame so the app still runs. Sprite loading is isolated in `Sprites.swift`.
- **Data source:** `ccusage` invoked as a subprocess. Prefer `ccusage` if on `PATH`, else fall back to `bunx ccusage`. Parse `--json` output.

**Requirements:** macOS + Swift toolchain (Xcode Command Line Tools: `xcode-select --install`). `bun` (for `bunx ccusage`) or `ccusage` installed.

---

## 3. Data model — what ccusage gives us

### 3a. The burn rate (Claude only) — drives the cat
`ccusage blocks --active --json` → `blocks[0]`:

```jsonc
{
  "isActive": true,
  "startTime": "2026-05-25T03:00:00.000Z",
  "endTime":   "2026-05-25T08:00:00.000Z",
  "costUSD": 46.96,
  "totalTokens": 60840085,
  "burnRate": {
    "costPerHour": 19.55,
    "tokensPerMinute": 422153.39,             // includes cache reads — huge, noisy
    "tokensPerMinuteForIndicator": 3514.13    // ← purpose-built for an indicator. USE THIS.
  },
  "projection": { "remainingMinutes": 113, "totalCost": 83.78, "totalTokens": 108543418 }
}
```

- When there is **no active block**, `blocks` is empty / `burnRate` is `null` → cat **sleeps**.

> **Live rate (the cat's actual signal).** `burnRate.tokensPerMinuteForIndicator` turned out to be a *cumulative average over the whole active block* (≈ `(input+output) ÷ block-elapsed-minutes`). Over a multi-hour block it barely moves second-to-second — useless for a RunCat-style live feel (verified: it drifted `4297→4328` over 25s while real work was ~19,700/min). So the cat is driven by a **self-computed recent rate**: we differentiate the block's cumulative `tokenCounts.inputTokens + outputTokens`. Cache reads (the 98M+ noise in `totalTokens`) and bursty cache-creation are excluded. ccusage's indicator is still shown in the dropdown as "Block avg". New-block resets are detected via `startTime`.
>
> **Rolling window (not a single interval).** Token logging is *bursty* — the model only writes new input+output when an assistant turn completes — so a one-poll-interval delta flickers to `0` between turns even while you're actively working. Instead we keep a ~60s rolling window of `(time, cumulative input+output)` samples and compute the rate across the whole window. Result: the rate stays alive during activity and **decays smoothly** when you stop (verified: `7111 → 3533 → 2347/min` as a burst aged out), instead of snapping to 0. Window length is `rateWindow` in `UsagePoller.swift`.

> Constraint discovered during spec: `blocks` is **Claude-only**. `ccusage codex blocks` errors with *"only available for Claude Code usage."* So only Claude has a ccusage-provided live rate.

### 3b. Per-agent breakdown (dropdown) — today's usage
Probe **Claude + Codex only** (decided): `ccusage claude daily --json` and `ccusage codex daily --json`, read today's row → tokens + cost. An agent with no usage today is omitted. (Easy to extend to more subcommands — `opencode`, `amp`, `droid`, `gemini`, `copilot`, … — later.)

`<agent> daily --json` → `{ "daily": [...], "totals": {...} }`, ascending by date. Take the last row where `date == today` (local tz). Verified Codex row shape:

```jsonc
{
  "date": "2026-05-25",
  "inputTokens": 69084, "outputTokens": 4062,
  "cachedInputTokens": 272896, "reasoningOutputTokens": 1369,
  "totalTokens": 346042, "costUSD": 1.51,
  "models": { "gpt-5.5": { "totalTokens": 346042, ... } }
}
```

---

## 4. Architecture

```
tokencat/
  Package.swift
  SPEC.md
  Sources/tokencat/
    main.swift          # NSApplication bootstrap, accessory policy
    AppDelegate.swift   # owns NSStatusItem + menu; wires poller -> animator -> UI
    UsagePoller.swift    # spawns ccusage on a background queue, parses JSON -> UsageSnapshot
    CatAnimator.swift    # maps burn rate -> fps; advances frames on a display timer
    Sprites.swift        # loads sprite PNGs into [NSImage] (template); emoji fallback
    Format.swift         # 3514 -> "3.5k", 60840085 -> "60.8M", $ formatting
  assets/
    run/    run_0.png .. run_7.png   # 8-frame run cycle, 120x80 (DONE)
    sleep/  sleep_0.png, sleep_1.png # 2-frame breathing loop, 120x80 (DONE)
    preview.png                      # contact sheet of all 10 frames (review only)
    test-cat.png                     # initial single-frame proof (unused)
```

**Two independent timers:**
1. **Poll timer** (default **15s**): runs `ccusage` off the main thread, parses, publishes a `UsageSnapshot` (burn rate, costs, projection, per-agent rows, state). Never blocks the UI.
2. **Animation timer**: ticks at the current FPS, advancing the cat frame. Decoupled from polling so the cat animates smoothly between data refreshes.

```
UsageSnapshot
  state: .running | .idle | .loading | .error(String)
  tokensPerMinIndicator: Double
  costPerHour, blockCostUSD, projectedBlockCostUSD: Double
  blockStart: Date?
  perAgent: [(name, tokensToday, costToday)]
```

---

## 5. The mapping (the heart of it)

Burn rate spans orders of magnitude, so map on a **log scale** to FPS.

`rate` here = the **live** Δ(input+output)/min (see §3a), not the ccusage indicator.

```
rMin   = 500     tok/min   (slow trot floor)
rMax   = 50000   tok/min   (full sprint cap)
fpsMin = 3, fpsMax = 18
idleThreshold = 200  tok/min
coastSeconds  = 30   (stay running this long after rate drops, before sleeping)

if (no active block OR rate <= idleThreshold) for longer than coastSeconds:
    state = idle, fps = 0 (sleep frames)
else:
    state = running
    x   = clamp((log10(max(rate, rMin)) - log10(rMin)) / (log10(rMax) - log10(rMin)), 0, 1)
    fps = fpsMin + x * (fpsMax - fpsMin)
```

Calibrated for the live Δ(input+output) rate, which is ~0 when idle and roughly 5k–50k/min during active generation: `~5k` → ~10.5 fps, `~20k` → ~15 fps (brisk run), `50k+` pegs the 18 fps sprint, `500` → 3 fps trot. `coastSeconds` keeps the cat from napping during slow think-time between bursts. All constants live at the top of `CatAnimator.swift` for easy tuning (e.g. raise `rMax` if your cat sprints too readily, or add `cacheCreationInputTokens` to the live-rate basis to make it react to large context loads).

**Sprite states** (driven by the same `x`/fps):
- idle / no active block → **sleep** sprite, animation stopped (or a slow 2-frame breathing loop).
- active → **run-cycle** sprites cycled at the mapped fps. Higher burn ⇒ higher fps ⇒ faster cat. (Optional later: a distinct "sprint" cycle above x > 0.66.)

`CatAnimator` holds the current state's `[NSImage]` and advances the frame index each tick (tick interval = `1/fps`). Frames are template images, so AppKit tints them to match the menu bar automatically.

---

## 6. Menu bar + dropdown

**Menu-bar button:** `button.image` = current sprite frame (template) **+** `button.title` = ` 3.5k/m` tokens/min, **always**. Truest to "token burning". When idle, the title is cleared and only the sleeping sprite shows. *(A dropdown toggle could later switch the stat to $/hr or hide it.)*

**Dropdown (rebuilt each poll):**
```
🔥 Now: 19.7k tok/min        ← live rate
Block avg: 4.3k tok/min      ← ccusage indicator, for context
Cost/hr: $19.55
This block: $46.96  (since 03:00)
Projected block: $83.78
────────────────────────
Today by agent
  Claude:  60.8M tok · $46.96
  Codex:    346K tok · $1.51
────────────────────────
Refresh: 15s            ▸   (submenu: 5s / 15s / 30s / 60s)
Quit TokenCat           ⌘Q
```

Idle state → header shows `😴 Idle — no active session`. Error → `⚠️ ccusage not found` + hint.

---

## 7. ccusage invocation details

- Resolve command once: `ccusage` on `PATH` → else `bunx ccusage`. Run through a login shell (`/bin/zsh -lc`) so PATH/bun are found.
- Use **`--offline` (`-O`)** on polls after the first successful online fetch, to stay snappy and avoid hammering the pricing API each tick (pricing may be slightly stale — acceptable).
- All subprocess work on a background `DispatchQueue`; publish results to main thread.
- **Parse stdout only.** `bunx` writes "Resolving dependencies…" noise to **stderr**; mixing them breaks JSON parsing. Read the process's stdout pipe and ignore stderr.
- First `bunx` run downloads the package (slow, possibly network) → show `⏳ loading` until first snapshot arrives; never freeze the UI.

---

## 8. Edge cases

| Case | Behavior |
|---|---|
| No active Claude block | Sleeping cat; dropdown "Idle — no active session" |
| `burnRate` null | Treat as idle |
| ccusage / bun missing | `⚠️` glyph; dropdown shows install hint; keep retrying |
| First-run bunx download | `⏳`, non-blocking |
| Agent has no usage today | Omit from breakdown |
| Token/cost formatting | `3.5k`, `60.8M`; `$19.55` |
| Timezone / block boundary | Use ccusage's system-tz default |

---

## 9. Build phases

0. **Sprite sheet. ✅ DONE.** 8 run + 2 sleep monochrome silhouette frames (120×80, transparent, binary-black) generated via Codex `$imagegen` into `assets/run/` and `assets/sleep/`. *Regenerate recipe:* `codex exec --skip-git-repo-check --sandbox workspace-write` with a prompt asking for a solid-black side-profile cat silhouette on transparent bg, an 8-frame run strip + 2-frame sleep strip, then PIL post-processing (slice on transparent gutter columns, alpha-trim, scale-to-fit, bottom-align on a 120×80 canvas, binarize alpha).
1. **MVP — the cat runs.** SPM executable, status item showing sprite + tokens/min, poll `ccusage blocks --active --json`, log→fps mapping, run/sleep states, Quit. *(Claude-only; this is the whole "wow".)*
2. **Dropdown stats + per-agent breakdown.** Cost/hr, block cost, projection, and `ccusage <agent> daily` per-agent rows for Claude + Codex (your ask).
3. **Polish.** Refresh-interval submenu, error/loading states, `--offline` optimization, optional "sprint" cycle.
4. **Packaging ✅ + later.** **Done:** `./package.sh` produces `build/TokenCat.app` — `LSUIElement` menu-bar agent, assets in `Contents/Resources/assets/`, Codex-generated icon converted to `AppIcon.icns` (sips + iconutil), ad-hoc signed. Sprite loader checks `Bundle.main.resourceURL/assets` first so the bundle is self-contained. **Still later/optional:** launch-at-login, spend alerts, notarization for distribution, self-computed unified burn rate across all agents.

---

## 10. Decisions (finalized)

All decisions are finalized — the spec is buildable as written. Constants are defaults that live at the top of their respective files and are trivially tunable after we see it run.

| Decision | Final value | Note |
|---|---|---|
| Menu-bar content | sprite + tokens/min, always (hidden when idle) | toggle to $/hr is a later nicety |
| Per-agent breakdown | Claude + Codex only | extend to more `ccusage` subcommands later |
| Sprites | 8 run + 2 sleep monochrome silhouettes, 120×80, template images | generated; emoji fallback |
| Sprint cap `rMax` | **12000** tok/min | tuned so normal heavy sessions sprint |
| Trot floor `rMin` | **200** tok/min | |
| FPS range | **3 → 18** | |
| Idle threshold | **≤30** tok/min | with **30s coast** so it doesn't nap mid-session |
| Refresh interval | **15s** default (submenu 5/15/30/60s) | 5s allowed but flagged wasteful given `bunx` spawn cost |

**Deferred (explicitly out of scope until later phases):** packaging as `.app`, launch-at-login, spend alerts/notifications, a "sprint" sprite cycle, and a self-computed unified burn rate that lets non-Claude agents drive the cat too (§9 Phase 4).
