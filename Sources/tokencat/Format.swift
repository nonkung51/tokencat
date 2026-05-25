import Foundation

/// Number / cost formatting helpers (SPEC §8): 3514 -> "3.5k", 60840085 -> "60.8M".
enum Fmt {
    /// Abbreviated token count: <1k as integer, k for thousands, M for millions.
    static func tokens(_ n: Double) -> String {
        let v = abs(n)
        if v >= 1_000_000 {
            return String(format: "%.1fM", n / 1_000_000)
        } else if v >= 1_000 {
            let k = n / 1_000
            return k >= 100 ? String(format: "%.0fk", k) : String(format: "%.1fk", k)
        } else {
            return String(format: "%.0f", n)
        }
    }

    static func cost(_ n: Double) -> String { String(format: "$%.2f", n) }

    /// Burn rate as shown in the menu bar, e.g. "3.5k/m".
    static func rate(_ tokensPerMin: Double) -> String { "\(tokens(tokensPerMin))/m" }
}
