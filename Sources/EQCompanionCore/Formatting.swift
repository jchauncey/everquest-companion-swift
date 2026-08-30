// Formatting helpers the surfaces share. Fixed en-US spellings, matching the engine's own cells
// (`Aug 19, 04:21 PM`) so a value the app renders sits beside one the engine rendered without a
// visible seam.
import Foundation

public enum Format {
    private static let kb = 1024.0
    private static let units = ["KB", "MB", "GB", "TB"]

    /// `148.8 MB` — base 1024, one decimal above a kilobyte, whole bytes below.
    public static func bytes(_ bytes: Int64) -> String {
        if bytes < 0 { return "0 B" }
        if Double(bytes) < kb { return "\(bytes) B" }
        var value = Double(bytes) / kb
        var unit = 0
        while value >= kb, unit < units.count - 1 {
            value /= kb
            unit += 1
        }
        return String(format: "%.1f %@", value, units[unit])
    }

    /// A coarse duration for an estimate: `40s`, `3m`, `1h 12m`.
    public static func duration(ms: Double) -> String {
        let seconds = max(1, Int((ms / 1000).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// A clock reading for a timer bar: `4m 30s`, `12s`, `1h 05m`. Negative reads as `0s`.
    public static func clock(ms: Int64) -> String {
        let total = max(0, Int(ms / 1000))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    /// `8.0k`, `1.2M`, `732` — the engine's own k/M scaling for a meter total.
    public static func compact(_ n: Double) -> String {
        let a = abs(n)
        if a >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if a >= 1_000 { return String(format: "%.1fk", n / 1_000) }
        return String(Int(n.rounded()))
    }

    /// `181 dps`
    public static func rate(_ n: Double) -> String {
        "\(Int(n.rounded())) dps"
    }

    /// `1,234`
    public static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d, hh:mm a"
        return f
    }()

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    /// `Aug 19, 04:21 PM` from epoch milliseconds, in the local zone. 0 is an unknown instant.
    public static func stamp(ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return stamp.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    public static func time(ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return timeOnly.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    public static func date(ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return dateOnly.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// `3 min ago`, `just now`, `2 h ago` — freshness wording for a row read against now.
    public static func ago(ms: Int64, now: Int64) -> String {
        guard ms > 0 else { return "" }
        let s = max(0, (now - ms) / 1000)
        if s < 10 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }

    /// `44s`, `2m 10s` from a duration in seconds.
    public static func seconds(_ sec: Double) -> String {
        clock(ms: Int64(sec * 1000))
    }

    /// `56.4%`
    public static func pct(_ p: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", p)
    }
}
