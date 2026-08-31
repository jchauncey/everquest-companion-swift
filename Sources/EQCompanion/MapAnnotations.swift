// The generated "Wiki annotations" label pack: every mob position the wiki states, written as
// ordinary map label files (`P x, y, z, r, g, b, size, label`) into the user mappacks folder, so
// the existing pack machinery — discovery, the Labels menu, shadowing — treats it like any pack
// a person installed. The map's gold dots and these labels are the same data; a pack label that
// disagrees with a dot (a stale hand-placed annotation) is exactly what this pack replaces.
import Foundation

@MainActor
enum MapAnnotations {
    nonisolated static let packDirName = "Wiki annotations"
    /// The pack id the scanner will derive (the directory name, lowercased).
    nonisolated static var packId: String { packDirName.lowercased() }

    nonisolated static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EQCompanion/mappacks/\(packDirName)", isDirectory: true)
    }

    struct Result { var zones = 0; var labels = 0 }

    /// Write (or rewrite) the pack: one `<stem>_1.txt` per zone that has any placed wiki mob.
    /// The whole pack is regenerated so a mob the wiki moved never leaves a stale file behind.
    @discardableResult
    static func generate(into dir: URL = MapAnnotations.dir) throws -> Result {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = Result()
        for z in GameData.shared.zones {
            var lines: [String] = []
            for row in MapPaneRows.mobRows(zoneName: z.name) where row.kind == .mob {
                for pin in row.pins {
                    // The game's label convention: underscores, shown as spaces. Gold, mid size.
                    let label = row.name.replacingOccurrences(of: ",", with: " ")
                        .replacingOccurrences(of: " ", with: "_")
                    lines.append(String(format: "P %.4f, %.4f, 0.0000, 217, 178, 95, 2, %@",
                                        pin.x, pin.y, label))
                }
            }
            guard !lines.isEmpty else { continue }
            let url = dir.appendingPathComponent("\(z.short)_1.txt")
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            out.zones += 1
            out.labels += lines.count
        }
        return out
    }
}
