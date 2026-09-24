// The openpeon sound-pack registry, ported from src/main/packRegistry.ts + src/main/sounds.ts.
//
// Three jobs: list the registry (24 h cached on disk, offline-tolerant), install a pack, remove
// one. The Electron installer pulls the GitHub release TARBALL and untars it in memory; this one
// fetches `openpeon.json` and each audio file with URLSession, which is more requests but no tar
// reader — and it lands the SAME manifest, because the CESP → manifest conversion below is the
// same one (`cespToManifestSounds` + `deriveSoundId`), so a soundId here matches a Windows
// install byte for byte.
//
// THE REGISTRY IS UNTRUSTED. A row's `name` becomes a directory and its `source_*` fields become a
// URL, so every row is validated at INGEST (a bad row drops, the rest still work) and again before
// any path is built. The allowlists are `src/main/security.ts`'s, transcribed.
import Foundation
import EQCompanionCore

/// One row of the registry index.
struct RegistryPack: Identifiable, Equatable {
    var name: String
    var displayName: String
    var author: String
    var summary: String
    var license: String
    var soundCount: Int
    var totalSizeBytes: Int
    var sourceRepo: String
    var sourceRef: String
    var sourcePath: String
    var categories: [String]
    var version: String
    var trustTier: String
    var id: String { name }

    static func from(_ v: JSONValue) -> RegistryPack? {
        guard let name = v["name"].string else { return nil }
        return RegistryPack(
            name: name,
            displayName: v["display_name"].string ?? name,
            author: v["author"]["name"].string ?? "",
            summary: v["description"].string ?? "",
            license: v["license"].string ?? "see source repo",
            soundCount: v["sound_count"].int ?? 0,
            totalSizeBytes: v["total_size_bytes"].int ?? 0,
            sourceRepo: v["source_repo"].string ?? "",
            sourceRef: v["source_ref"].string ?? "",
            sourcePath: v["source_path"].string ?? ".",
            categories: (v["categories"].array ?? []).compactMap(\.string),
            version: v["version"].string ?? "",
            trustTier: v["trust_tier"].string ?? "")
    }

    func toJSON() -> JSONValue {
        ["name": .string(name), "display_name": .string(displayName),
         "author": ["name": .string(author)], "description": .string(summary),
         "license": .string(license), "sound_count": .int(Int64(soundCount)),
         "total_size_bytes": .int(Int64(totalSizeBytes)), "source_repo": .string(sourceRepo),
         "source_ref": .string(sourceRef), "source_path": .string(sourcePath),
         "categories": .array(categories.map { .string($0) }), "version": .string(version),
         "trust_tier": .string(trustTier)]
    }

    /// raw.githubusercontent base for this pack's pinned tree (no trailing slash).
    var rawBase: String {
        let sub = (sourcePath == "." || sourcePath.isEmpty)
            ? "" : sourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = "https://raw.githubusercontent.com/\(sourceRepo)/\(sourceRef)"
        return sub.isEmpty ? root : "\(root)/\(sub)"
    }
}

/// The one pack the app provisions on first launch, inlined so first run needs ZERO registry
/// requests — field for field the shape the index serves (`DEFAULT_PACK` in defaultPacks.ts).
let defaultRegistryPack = RegistryPack(
    name: defaultAlertPackId,
    displayName: "Alan Rickman",
    author: "Doomspork",
    summary: "Claudette notification sounds, voiced in the manner of the late Alan Rickman. Slow. Deliberate. Faintly amused.",
    license: "CC-BY-4.0",
    soundCount: 60,
    totalSizeBytes: 1_964_096,
    sourceRepo: "utensils/openpeon-alan-rickman-soundpack",
    sourceRef: "v1.1.2",
    sourcePath: ".",
    categories: ["input.required", "resource.limit", "session.start", "task.acknowledge",
                 "task.complete", "task.error"],
    version: "1.1.2",
    trustTier: "verified")

/// Where an install has got to.
enum PackInstallPhase: Equatable {
    case downloading(done: Int, total: Int)
    case converting
    case failed(String)

    var text: String {
        switch self {
        case .downloading(let d, let t): return t > 0 ? "Downloading \(d)/\(t)…" : "Downloading…"
        case .converting: return "Writing manifest…"
        case .failed(let m): return m
        }
    }
}

enum SoundPackError: LocalizedError {
    case unsafe(String)
    case http(String, Int)
    case badManifest(String)
    case tooLarge(String)
    case busy(String)
    var errorDescription: String? {
        switch self {
        case .tooLarge(let url): return "\(URL(string: url)?.lastPathComponent ?? url) is larger than a sound pack may be"
        case .busy(let name): return "\(name) is already being installed"
        case .unsafe(let what): return "registry pack \(what) is not a valid identifier"
        case .http(let url, let code): return "HTTP \(code) for \(URL(string: url)?.lastPathComponent ?? url)"
        case .badManifest(let why): return why
        }
    }
}

// MARK: - CESP → our manifest

/// Category → the label prefix our manifest uses so the picker reads well (`CESP_CATEGORY_LABEL`).
let cespCategoryLabel: [String: String] = [
    "session.start": "Start", "session.end": "End", "task.acknowledge": "Acknowledge",
    "task.complete": "Complete", "task.error": "Error", "task.progress": "Progress",
    "input.required": "Input", "resource.limit": "Limit", "user.spam": "Spam"
]

/// The order those categories are offered in, so a converted pack lists the way Windows lists it.
private func slug(_ s: String) -> String {
    var out = ""
    for ch in s.lowercased() {
        if ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

/// `deriveSoundId`: `<category-slug>-<file-slug>`, de-duped with a numeric suffix.
func deriveSoundId(category: String, file: String, taken: inout Set<String>) -> String {
    let base = (file as NSString).lastPathComponent
    let stem = (base as NSString).deletingPathExtension
    let catSlug = slug(category)
    let baseSlug = slug(stem).isEmpty ? "sound" : slug(stem)
    var id = catSlug.isEmpty ? baseSlug : "\(catSlug)-\(baseSlug)"
    if taken.contains(id) {
        var i = 2
        while taken.contains("\(id)-\(i)") { i += 1 }
        id = "\(id)-\(i)"
    }
    taken.insert(id)
    return id
}

/// One converted line: the manifest entry plus the path to fetch it from, relative to the raw base.
struct ConvertedSound {
    var soundId: String
    var label: String
    /// `sounds/<basename>` — where it lands on disk.
    var file: String
    /// The CESP's own path, which may already carry a `sounds/` prefix — what we GET.
    var sourceFile: String
}

/// `cespToManifestSounds`, with the source path kept alongside so the installer knows what to GET.
func convertCesp(_ cesp: JSONValue) -> [ConvertedSound] {
    var taken = Set<String>()
    var out: [ConvertedSound] = []
    let categories = cesp["categories"].object ?? [:]
    for category in categories.keys.sorted() {
        let prefix = cespCategoryLabel[category] ?? category
        let value = categories[category] ?? .null
        let list = value["sounds"].array ?? value.array ?? []
        for s in list {
            let sourceFile = s.string ?? s["file"].string ?? ""
            guard !sourceFile.isEmpty else { continue }
            let id = deriveSoundId(category: category, file: sourceFile, taken: &taken)
            let name = (sourceFile as NSString).lastPathComponent
            let raw = s["label"].string?.trimmingCharacters(in: .whitespaces)
            let label = (raw?.isEmpty == false) ? raw! : name
            out.append(ConvertedSound(soundId: id, label: "\(prefix) · \(label)",
                                      file: "sounds/\(name)", sourceFile: sourceFile))
        }
    }
    return out
}

// MARK: - Validation (src/main/security.ts, transcribed)

func isSafePackId(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= 128 else { return false }
    guard let first = id.first, first.isASCII, first.isLetter || first.isNumber || first == "_" else { return false }
    return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
}

func isSafeSourceRepo(_ v: String) -> Bool {
    guard !v.isEmpty, v.count <= 140 else { return false }
    let parts = v.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    let owner = String(parts[0]), repo = String(parts[1])
    guard !owner.isEmpty, owner.count <= 39, let o = owner.first, o.isASCII, o.isLetter || o.isNumber,
          owner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
    guard !repo.isEmpty, repo.count <= 100, repo != ".", repo != "..",
          repo.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") })
    else { return false }
    return true
}

func isSafeSourceRef(_ v: String) -> Bool {
    guard !v.isEmpty, v.count <= 100, !v.contains("..") else { return false }
    guard let f = v.first, f.isASCII, f.isLetter || f.isNumber else { return false }
    return v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
}

func isSafeSourcePath(_ v: String) -> Bool {
    guard v.count <= 200 else { return false }
    if v.isEmpty || v == "." { return true }
    if v.contains("\\") || v.contains("\0") || v.hasPrefix("/") { return false }
    if v.count >= 2, let f = v.first, f.isLetter, Array(v)[1] == ":" { return false }
    var trimmed = v
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    if trimmed.isEmpty { return false }
    return trimmed.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { seg in
        !seg.isEmpty && seg != "." && seg != ".." &&
        seg.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }
}

func isValidRegistryRow(_ p: RegistryPack) -> Bool {
    isSafePackId(p.name) && isSafeSourceRepo(p.sourceRepo) && isSafeSourceRef(p.sourceRef)
        && isSafeSourcePath(p.sourcePath)
}

// MARK: - The registry itself

@MainActor
@Observable
final class SoundPackRegistry {
    private(set) var packs: [RegistryPack] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var fromCache = false
    private(set) var dropped = 0
    /// Per-pack install state, keyed by pack name.
    private(set) var progress: [String: PackInstallPhase] = [:]
    private(set) var busy: Set<String> = []

    static let url = "https://peonping.github.io/registry/index.json"
    private static let ttl: TimeInterval = 24 * 60 * 60

    private static var cacheFile: URL {
        AlertPlayer.packsDir.deletingLastPathComponent().appendingPathComponent("registry-cache.json")
    }

    /// Packs the user REMOVED. Presence is not precedence: a deletion is a statement, so the
    /// first-launch provisioning skips a tombstoned id forever. Installing it again clears the
    /// stone, which is the only way back and is one click.
    private static let tombstoneKey = "alerts.removedSoundPacks"

    static func tombstones() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: tombstoneKey) ?? [])
    }

    static func tombstone(_ id: String, on: Bool) {
        var s = tombstones()
        if on { s.insert(id) } else { s.remove(id) }
        UserDefaults.standard.set(Array(s).sorted(), forKey: tombstoneKey)
    }

    // MARK: Listing

    func load(force: Bool = false) async {
        loading = true
        defer { loading = false }
        if !force, let cached = Self.readCache(), Date().timeIntervalSince1970 - cached.at < Self.ttl {
            packs = cached.packs
            fromCache = true
            error = nil
            return
        }
        do {
            let data = try await Self.get(Self.url, limit: Limits.indexBytes)
            let v = try JSONValue.parse(data)
            let rows = (v["packs"].array ?? []).compactMap(RegistryPack.from)
            let kept = rows.filter(isValidRegistryRow)
            dropped = rows.count - kept.count
            packs = kept
            fromCache = false
            error = nil
            Self.writeCache(kept)
        } catch {
            // Offline is a state, not a failure: serve the cache and say where it came from.
            let cached = Self.readCache()
            packs = cached?.packs ?? packs
            fromCache = cached != nil
            self.error = "\(error)"
        }
    }

    private static func readCache() -> (at: TimeInterval, packs: [RegistryPack])? {
        guard let data = try? Data(contentsOf: cacheFile), let v = try? JSONValue.parse(data) else { return nil }
        let rows = (v["packs"].array ?? []).compactMap(RegistryPack.from).filter(isValidRegistryRow)
        guard !rows.isEmpty else { return nil }
        return (v["at"].double ?? 0, rows)
    }

    private static func writeCache(_ packs: [RegistryPack]) {
        let doc: JSONValue = ["at": .double(Date().timeIntervalSince1970),
                              "packs": .array(packs.map { $0.toJSON() })]
        try? Data(doc.serializedString().utf8).write(to: cacheFile, options: .atomic)
    }

    // MARK: Install / remove

    func install(_ pack: RegistryPack, player: AlertPlayer) async {
        guard !busy.contains(pack.name) else { return }
        busy.insert(pack.name)
        progress[pack.name] = .downloading(done: 0, total: pack.soundCount)
        defer { busy.remove(pack.name) }
        do {
            try await Self.install(pack) { [weak self] phase in
                self?.progress[pack.name] = phase
            }
            Self.tombstone(pack.name, on: false)
            progress[pack.name] = nil
            player.invalidate()
        } catch {
            progress[pack.name] = .failed("\(error.localizedDescription)")
        }
    }

    func remove(_ id: String, player: AlertPlayer) {
        guard id != userSoundsPackId else { return }
        guard isSafePackId(id) else { return }
        let dir = AlertPlayer.packsDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        Self.tombstone(id, on: true)
        progress[id] = nil
        player.invalidate()
    }

    /// The whole install, static so first-launch provisioning can run it with no view alive.
    static func install(_ pack: RegistryPack, onProgress: @MainActor (PackInstallPhase) -> Void) async throws {
        guard isSafePackId(pack.name) else { throw SoundPackError.unsafe("name") }
        guard pack.name != userSoundsPackId else { throw SoundPackError.unsafe("name") }
        guard isSafeSourceRepo(pack.sourceRepo), isSafeSourceRef(pack.sourceRef),
              isSafeSourcePath(pack.sourcePath) else { throw SoundPackError.unsafe("source fields") }

        // One install per pack at a time: first-launch provisioning and a click on Install for the
        // same pack would otherwise race over the same pack directory.
        // `install` is main-actor isolated (the class is), so the claim and release are plain calls.
        guard claim(pack.name) else { throw SoundPackError.busy(pack.name) }
        defer { release(pack.name) }

        let base = pack.rawBase
        let cespData = try await get("\(base)/openpeon.json", limit: Limits.manifestBytes)
        guard let cesp = try? JSONValue.parse(cespData) else {
            throw SoundPackError.badManifest("openpeon.json is not valid JSON")
        }
        let sounds = convertCesp(cesp)
        guard !sounds.isEmpty else { throw SoundPackError.badManifest("no sounds after conversion") }

        let fm = FileManager.default
        let packDir = packsDirChild(pack.name)
        let stage = packsDirChild("\(pack.name).installing-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: stage.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        var swapped = false
        defer { if !swapped { try? fm.removeItem(at: stage) } }

        var wrote = 0
        var total = 0
        for (i, s) in sounds.enumerated() {
            await onProgress(.downloading(done: i, total: sounds.count))
            // The path came out of the pack's own manifest; normalize and refuse traversal anyway.
            let rel = s.sourceFile.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel.split(separator: "/").contains("..") { continue }
            // So is the destination name: a `..` or `.` would resolve out of `sounds/` (or onto
            // it), so it is skipped rather than written and failed on, which aborted the install.
            let leaf = (s.file as NSString).lastPathComponent
            if leaf.isEmpty || leaf == "." || leaf == ".." { continue }
            let dest = stage.appendingPathComponent(s.file).standardizedFileURL
            guard dest.path.hasPrefix(stage.standardizedFileURL.path + "/") else { continue }
            guard let bytes = try? await get("\(base)/\(rel)", limit: Limits.soundBytes) else { continue }
            total += bytes.count
            if total > Limits.packBytes { throw SoundPackError.tooLarge(pack.name) }
            try bytes.write(to: dest, options: .atomic)
            wrote += 1
        }
        guard wrote > 0 else {
            throw SoundPackError.badManifest("pack contained no audio files")
        }

        onProgress(.converting)
        var map: [String: JSONValue] = [:]
        for s in sounds where fm.fileExists(atPath: stage.appendingPathComponent(s.file).path) {
            map[s.soundId] = ["file": .string(s.file), "label": .string(s.label)]
        }
        let displayName = [pack.displayName, cesp["display_name"].string ?? "", pack.name]
            .first { !$0.isEmpty } ?? pack.name
        let manifest: JSONValue = [
            "id": .string(pack.name),
            "name": .string(displayName),
            "sounds": .object(map),
            "license": .string(cesp["license"].string ?? pack.license),
            "source": ["repo": .string(pack.sourceRepo), "ref": .string(pack.sourceRef)]
        ]
        try Data((manifest.pretty() + "\n").utf8)
            .write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)

        // Swap the staged dir into place, so a mid-install failure never shadows a good pack.
        try? fm.removeItem(at: packDir)
        try fm.moveItem(at: stage, to: packDir)
        swapped = true
    }

    /// Byte ceilings. The registry is third-party content: a manifest pointing at a huge file must
    /// not be buffered whole, and a pack is a handful of short clips.
    enum Limits {
        static let indexBytes = 8 << 20
        static let manifestBytes = 1 << 20
        static let soundBytes = 10 << 20
        static let packBytes = 100 << 20
    }

    private static var installing = Set<String>()
    private static func claim(_ name: String) -> Bool { installing.insert(name).inserted }
    private static func release(_ name: String) { installing.remove(name) }

    private static func packsDirChild(_ name: String) -> URL {
        AlertPlayer.packsDir.appendingPathComponent(name, isDirectory: true)
    }

    /// GET a URL and buffer the body, refusing past `limit` bytes. Redirects follow `RawGitHubOnly`.
    static func get(_ url: String, limit: Int) async throws -> Data {
        guard let u = URL(string: url) else { throw SoundPackError.http(url, 0) }
        var req = URLRequest(url: u, timeoutInterval: 60)
        req.setValue("everquest-companion", forHTTPHeaderField: "User-Agent")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req, delegate: RawGitHubOnly.shared)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SoundPackError.http(url, code) }
        if resp.expectedContentLength > Int64(limit) { throw SoundPackError.tooLarge(url) }
        var data = Data()
        if resp.expectedContentLength > 0 { data.reserveCapacity(Int(resp.expectedContentLength)) }
        for try await b in bytes {
            data.append(b)
            if data.count > limit { throw SoundPackError.tooLarge(url) }
        }
        return data
    }

    // MARK: First launch

    /// Install the shipped pack if it is missing and the user has not thrown it away.
    ///
    /// ADDITIVE ONLY, AND ADDITIVE IS NOT UNCONDITIONAL. "Missing" means "not on disk AND not
    /// tombstoned" — deleting the pack used to work exactly until the next launch put it back.
    static func provisionDefaultPack(player: AlertPlayer) async {
        let id = defaultRegistryPack.name
        if tombstones().contains(id) { return }
        if FileManager.default.fileExists(
            atPath: packsDirChild(id).appendingPathComponent("manifest.json").path) { return }
        do {
            try await install(defaultRegistryPack) { _ in }
            player.invalidate()
        } catch {
            // Best effort and silent, exactly as provisionPacks.ts is: a failed run retries next
            // launch, and the Sound packs sheet installs it by hand meanwhile.
        }
    }
}

/// Sound-pack downloads follow a redirect only over https, and only to the host the request began
/// on or to raw.githubusercontent.com (every pack file URL is built on it). Anything else ends the
/// request at the redirect.
final class RawGitHubOnly: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RawGitHubOnly()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let u = request.url, u.scheme == "https",
              u.host == "raw.githubusercontent.com" || u.host == task.originalRequest?.url?.host else { return nil }
        return request
    }
}
