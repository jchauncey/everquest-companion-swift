// The Gear area: one nav row, four tabs. Character is first because it is the one that answers a
// question the player already has ("what am I wearing"); the other three are about what they could
// have instead.
//
// The heavy item index (11.5k pages) is built ONCE per process, off the main thread, and shared by
// three of the four tabs — so it is started here rather than by whichever tab happened to open
// first.
import SwiftUI
import EQCompanionCore

struct GearView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("eq.gear.tab") private var tab = "character"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SegmentPicker(selection: $tab, options: [
                    ("gear", "Gear"),
                    ("exaltations", "Exaltations"),
                    ("character", "Character"),
                    ("wishlist", "Wish list")
                ])
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(Theme.border)

            switch tab {
            case "gear": GearTableView()
            case "exaltations": ExaltationView()
            case "wishlist": WishListView()
            default: InventoryCharacterView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear {
            GearIndex.shared.start()
            WishListStore.shared.bind(character: model.attached)
        }
    }
}
