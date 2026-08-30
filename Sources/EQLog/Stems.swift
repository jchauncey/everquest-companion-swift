// The charm / crowd-control name stems (eqlog/src/stems.rs).
import Foundation

public enum Stems {
    private static let charmPlain = Re("(?i)beguile|alluring whispers|cajol|dictate|besiege|agacerie|beckon|command of druzzil|dominate|thrall of bones|enslave death|befriend animal|call of karana|tunare.s request|solon.s ((bewitching )?bravura|song of the sirens)")
    private static let charmWord = Re("(?i)(?-u:\\b)charm(?-u:\\b)")
    private static let allureWord = Re("(?i)(?-u:\\b)allure(?-u:\\b)")
    private static let cc = Re("(?i)mesmeriz|enthrall|entranc|dazzle|screaming terror|ensnar|immobiliz|suffocat|kelin.s lucid lullaby|pixie strike|sionachie.s dreams")
    private static let charmLine = Re("(?i)^charm(?-u:\\b)")

    public static func charmStemsTest(_ name: String) -> Bool {
        if charmPlain.isMatch(name) { return true }
        if charmWord.allCaptures(name).contains(where: { !JS.startsWithCI(name[$0.end...], " of ") }) { return true }
        return allureWord.allCaptures(name).contains(where: { !JS.startsWithCI(name[$0.end...], " of death") })
    }

    public static func ccStemsTest(_ name: String) -> Bool { cc.isMatch(name) }

    public static func classifyEffectLineIsCharm(_ line: String) -> Bool { charmLine.isMatch(line) }
}
