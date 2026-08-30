// `"Sat Aug 01 13:00:28 2026"` → epoch millis, on one IANA zone (eqlog/src/timestamp.rs).
//
// ECMA-262 resolves both DST corner cases at the offset in effect BEFORE the transition: the
// repeated hour reads at the earlier instant, the skipped hour at the offset read a day earlier.
import Foundation

public struct Civil: Equatable, Sendable {
    public var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year; self.month = month; self.day = day; self.hour = hour; self.minute = minute; self.second = second
    }
}

public final class Clock: @unchecked Sendable {
    public let tz: TimeZone
    private let stampRe = Re("^[0-9A-Za-z_]{3}\(JS.S)+([0-9A-Za-z_]{3})\(JS.S)+([0-9]{1,2})\(JS.S)+([0-9]{2}):([0-9]{2}):([0-9]{2})\(JS.S)+([0-9]{4})$")
    private lazy var localCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }()

    public init(tz: TimeZone) { self.tz = tz }

    public convenience init?(identifier: String) {
        guard let tz = TimeZone(identifier: identifier) else { return nil }
        self.init(tz: tz)
    }

    /// The host's zone (`host_timezone`).
    public static func host() -> Clock { Clock(tz: TimeZone.current) }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private var lastStamp = ""
    private var lastMs: Int64 = 0

    /// A stamp the pattern declines, or a date V8 would call NaN, is 0.
    ///
    /// Consecutive lines share a second, so the last answer is cached by the stamp's text.
    public func parseEQTimestamp(_ stamp: String) -> Int64 {
        if stamp == lastStamp { return lastMs }
        let ms = parseUncached(stamp)
        lastStamp = stamp
        lastMs = ms
        return ms
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28
        }
    }

    private func parseUncached(_ stamp: String) -> Int64 {
        let t = JS.trim(stamp)
        guard let m = stampRe.captures(t) else { return 0 }
        guard let month = Self.months.firstIndex(of: m.s(1).lowercased()) else { return 0 }
        let day = Int(m.s(2)) ?? 0, hour = Int(m.s(3)) ?? 99, min = Int(m.s(4)) ?? 99, sec = Int(m.s(5)) ?? 99, year = Int(m.s(6)) ?? 0
        guard day >= 1, day <= Self.daysInMonth(year, month + 1), hour < 24, min < 60, sec < 60, year > 0 else { return 0 }
        // The wall-clock fields read as if UTC, then resolved through the zone.
        let naive = TimeInterval(Self.daysFromCivil(year, month + 1, day) * 86400 + hour * 3600 + min * 60 + sec)
        return resolve(naive: naive) * 1000
    }

    /// Resolve wall-clock seconds (read as UTC) to the instant ECMA-262 picks on this zone.
    private func resolve(naive: TimeInterval) -> Int64 {
        let guessOff = TimeInterval(tz.secondsFromGMT(for: Date(timeIntervalSince1970: naive)))
        let altOff = TimeInterval(tz.secondsFromGMT(for: Date(timeIntervalSince1970: naive - guessOff)))
        var valid: [TimeInterval] = []
        for off in Set([guessOff, altOff]) {
            let inst = naive - off
            if TimeInterval(tz.secondsFromGMT(for: Date(timeIntervalSince1970: inst))) == off { valid.append(inst) }
        }
        if let earliest = valid.min() { return Int64(earliest) }
        // Skipped hour: the offset in effect a day earlier.
        let probe = naive - 86400
        let probeGuess = TimeInterval(tz.secondsFromGMT(for: Date(timeIntervalSince1970: probe)))
        let off = TimeInterval(tz.secondsFromGMT(for: Date(timeIntervalSince1970: probe - probeGuess)))
        return Int64(naive - off)
    }

    /// The wall clock an instant shows on this zone.
    public func civil(_ ms: Int64) -> Civil? {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let c = localCal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        guard let y = c.year, let mo = c.month, let da = c.day, let h = c.hour, let mi = c.minute, let s = c.second else { return nil }
        return Civil(year: y, month: mo, day: da, hour: h, minute: mi, second: s)
    }
}
