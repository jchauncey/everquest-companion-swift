// The wish list document: what you are trying to get, kept per character in UserDefaults.
//
// THE ITEM KEY IS THE IDENTITY. `addWish` is a no-op when the key is already on the list — first
// line wins — and `remove` drops the entry and its "got it" dismissal together, so a re-added wish
// comes back live rather than pre-dismissed.
//
// A DISMISSAL IS NOT A DELETION. `clearedDone` records the rows a player has stopped wanting to see
// on the route; the entries stay, which is why the header count is the whole document's and never
// what the filters left.
import Foundation
import Observation

struct WishEntry: Codable, Identifiable, Hashable {
    /// `GameData.nameKey(name)` — THE identity of a wish
    var itemKey: String
    var name: String
    /// `gear` (the item itself) or `donor` (an effect you want to extract off it)
    var kind: String
    /// donor wishes only: the effect and the socket it travels in
    var effect: String?
    var socket: String?
    var addedAt: Int64
    /// `user` or `planImport`
    var source: String
    var id: String { itemKey }
}

struct WishList: Codable {
    var entries: [WishEntry] = []
    /// wish ids the player has swept off the "Got it" strip — dismissed, never deleted
    var clearedDone: [String] = []
}

@MainActor
@Observable
final class WishListStore {
    static let shared = WishListStore()

    /// A list holds 500. Past that `add` is a no-op rather than an unbounded document.
    static let maxWishes = 500

    private(set) var list = WishList()
    private(set) var loaded = false
    private var storageKey = "eq.wishlist"

    /// Point the store at one character's document. Called before the first read; changing
    /// characters re-reads rather than migrating, because a wish is about a character's route.
    func bind(character: CharacterRef?) {
        let key = character.map { "eq.wishlist.\($0.name)_\($0.server)" } ?? "eq.wishlist"
        if key == storageKey && loaded { return }
        storageKey = key
        loaded = false
        load()
    }

    func load() {
        guard !loaded else { return }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let doc = try? JSONDecoder().decode(WishList.self, from: data) {
            list = doc
        } else {
            list = WishList()
        }
        loaded = true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func has(_ itemKey: String) -> Bool { list.entries.contains { $0.itemKey == itemKey } }

    func add(_ entry: WishEntry) {
        guard !has(entry.itemKey), list.entries.count < Self.maxWishes else { return }
        list.entries.append(entry)
        save()
    }

    func remove(_ itemKey: String) {
        list.entries.removeAll { $0.itemKey == itemKey }
        list.clearedDone.removeAll { $0 == itemKey }
        save()
    }

    /// Stop showing these on the route. They stay on the list; nothing is deleted.
    func clearDone(_ keys: [String]) {
        for k in keys where !list.clearedDone.contains(k) { list.clearedDone.append(k) }
        save()
    }
}
