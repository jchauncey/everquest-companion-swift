// What a bug report carries, and what it refuses to carry.
//
// This app has no upload: a report is a FILE the user saves and sends. That does not loosen the
// bright line the upstream report holds — GAMEPLAY DATA NEVER RIDES AUTOMATICALLY — because the
// user is going to send this to a stranger, and the whole document is therefore built and then
// REDACTED as one string before it is shown to anybody.
//
// Two redactions, run over the finished JSON rather than over each field, so a character name
// cannot survive by arriving through a field nobody thought about (the engine's `mark.log` is an
// absolute path to `eqlog_<Name>_<server>.txt`, and it is exactly that kind of arrival):
//
//   * every `eqlog_<Name>_<server>` becomes `eqlog_*`, so a path may name the FOLDER and never the
//     character;
//   * every known character name becomes `<character>`, whole words only.
//
// No line of the EverQuest log is in here at all — the app's own `client.log` is, and that is the
// file that records what this app did rather than what the player did.
import Foundation
import EQCompanionCore

enum BugReport {
    /// Bumped only for a breaking change to the file's shape.
    static let formatVersion = 1

    /// Lines of `client.log` a report carries.
    static let logLines = 200

    // MARK: - The redactor

    private static let eqlogRe = try! NSRegularExpression(
        pattern: "eqlog_[A-Za-z0-9]+_[A-Za-z0-9]+", options: [.caseInsensitive])

    /// Strip the two things a report may never carry. Idempotent: neither placeholder can match
    /// either pattern, so redacting a redacted report changes nothing.
    ///
    /// The caller's list of names is not the whole list: a log file name STATES the character whose
    /// log it is, so any `eqlog_<Name>_<server>` in the text names a character too — and it is the
    /// one name still readable on a machine where the install could not be resolved and the app
    /// therefore knows no characters at all.
    static func redact(_ text: String, names: [String]) -> String {
        var all = Set(names)
        let whole = NSRange(text.startIndex..., in: text)
        for m in eqlogRe.matches(in: text, range: whole) {
            guard let r = Range(m.range, in: text) else { continue }
            let stem = text[r].dropFirst("eqlog_".count).split(separator: "_")
            if let name = stem.first { all.insert(String(name)) }
        }
        var out = eqlogRe.stringByReplacingMatches(
            in: text, range: whole, withTemplate: "eqlog_*")
        for name in all.sorted() where name.count >= 2 {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let re = try? NSRegularExpression(pattern: "\\b\(escaped)\\b",
                                                   options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<character>")
        }
        return out
    }

    // MARK: - The document

    /// Everything the report states, as data. Pure — every input is passed in, so the shape can be
    /// checked without an app, an engine or a disk.
    static func compose(what: String,
                        savedAt: Date,
                        version: String,
                        startup: StartupProfile?,
                        os: String,
                        arch: String,
                        install: ResolvedInstall?,
                        characterCount: Int,
                        attached: Bool,
                        health: HealthReading?,
                        perf: JSONValue,
                        budgets: JSONValue,
                        log: [String]) -> JSONValue {
        var doc: [String: JSONValue] = [
            "report": .string("eq-companion-bug-report"),
            "v": .int(Int64(formatVersion)),
            "savedAt": .string(ISO8601DateFormatter().string(from: savedAt)),
            "what": .string(what)
        ]
        var app: [String: JSONValue] = ["version": .string(version)]
        if let s = startup {
            app["startupMs"] = .int(Int64(s.totalMs.rounded()))
            app["startupComplete"] = .bool(s.complete)
            app["startupPhases"] = .object(Dictionary(uniqueKeysWithValues:
                s.timings.map { ($0.phase, JSONValue.int(Int64($0.durationMs.rounded()))) }))
        }
        doc["app"] = .object(app)
        doc["mac"] = .object([
            "os": .string(os),
            "arch": .string(arch),
            "cores": .int(Int64(ProcessInfo.processInfo.processorCount))
        ])
        var inst: [String: JSONValue] = ["found": .bool(install != nil),
                                         "characters": .int(Int64(characterCount)),
                                         "attached": .bool(attached)]
        if let i = install {
            inst["source"] = .string(i.source)
            inst["root"] = .string(i.root.path)
            inst["logsDir"] = .string(i.logsDir.path)
        }
        doc["install"] = .object(inst)
        var engine: [String: JSONValue] = ["perf": perf, "budgets": budgets]
        if let h = health {
            engine["health"] = .object([
                "status": .string(h.status),
                "epoch": .int(Int64(h.epoch)),
                "uptimeMs": .int(h.uptimeMs),
                "events": .int(Int64(h.events)),
                "offset": h.offset.map { JSONValue.int($0) } ?? .null,
                "lastEventTs": h.lastEventTs.map { JSONValue.int($0) } ?? .null,
                "logMtimeMs": h.logMtimeMs.map { JSONValue.int($0) } ?? .null
            ])
        } else {
            engine["health"] = .null
        }
        doc["engine"] = .object(engine)
        doc["clientLog"] = .array(log.map { .string($0) })
        return .object(doc)
    }

    /// The finished file: the document, serialized, then redacted as one string.
    static func text(_ doc: JSONValue, names: [String]) -> String {
        let raw: String
        if let data = try? JSONSerialization.data(withJSONObject: doc.anyValue,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            raw = s
        } else {
            raw = "{}"
        }
        return redact(raw, names: names)
    }

    // MARK: - Reading the machine

    /// The whole report for the app as it stands. The two engine asks are made here and nowhere
    /// else — a report is written when a button is pressed, never on a timer.
    @MainActor
    static func gather(model: AppModel, what: String) async -> String {
        var perf = JSONValue.null
        var budgets = JSONValue.null
        if model.client.isReady {
            perf = (try? await model.client.request(Op.perfSnapshot)) ?? .null
            budgets = (try? await model.client.request(Op.perfBudgets)) ?? .null
        }
        let doc = compose(what: what,
                          savedAt: Date(),
                          version: AppVersion.current,
                          startup: AppTiming.profile(),
                          os: ProcessInfo.processInfo.operatingSystemVersionString,
                          arch: machineArch(),
                          install: model.install,
                          characterCount: model.characters.count,
                          attached: model.attached != nil,
                          health: model.health,
                          perf: perf,
                          budgets: budgets,
                          log: tail(of: ClientLog.file, lines: logLines, fallback: model.debugLog))
        var names = Set(model.characters.map(\.name))
        if let a = model.attached { names.insert(a.name) }
        return text(doc, names: names.sorted())
    }

    /// The last `lines` lines of a file. The in-memory notes stand in when the file cannot be
    /// read, because an empty log in a bug report reads as "nothing happened".
    static func tail(of file: URL, lines: Int, fallback: [String] = []) -> [String] {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8)
        else { return Array(fallback.suffix(lines)) }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(all.suffix(lines)).filter { !$0.isEmpty }
    }

    /// `arm64` / `x86_64`, as the kernel names it.
    static func machineArch() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }

    /// `eq-companion-report-2026-08-29-2143.json`.
    static func suggestedFileName(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "eq-companion-report-\(f.string(from: now)).json"
    }
}
