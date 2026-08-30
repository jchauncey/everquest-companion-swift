// The committed game knowledge, as bundle resources: `Bundle.module` resolves to the resource
// bundle in a `swift run`, in tests, and inside the packaged .app alike.
import Foundation

public enum EQData {
    /// Inside a packaged .app the resource bundle sits in `Contents/Resources`; in a `swift run`
    /// or a test it is beside the executable, which is what `Bundle.module` resolves. Checked in
    /// that order because `Bundle.module` traps rather than returning nil when neither exists.
    public static let bundle: Bundle = {
        if let res = Bundle.main.resourceURL,
           let b = Bundle(url: res.appendingPathComponent("EQCompanion_EQData.bundle")) { return b }
        return Bundle.module
    }()

    /// `data/<name>` as bytes, or nil when the file is not shipped.
    public static func data(_ name: String) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "data") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// `data/<name>` as text (the JSON corpora are UTF-8).
    public static func text(_ name: String) -> String? {
        data(name).map { String(decoding: $0, as: UTF8.self) }
    }

    public static var dataDir: URL? { bundle.url(forResource: "data", withExtension: nil) }
    public static var imagesDir: URL? { bundle.url(forResource: "wiki-images", withExtension: nil) }
}
