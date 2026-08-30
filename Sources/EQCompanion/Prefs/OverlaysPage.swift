// Preferences → Overlays — the upstream OverlayAutoHideSetting, ToastSetting, AlertBannerSetting
// and ConCardSetting, plus the one half of GraphicsSetting that means anything on a Mac.
//
// STATE, NEVER PROCESS: the captions say what happens and what the current setting means. Nothing
// here mentions the poll, the process table or the frontmost-application check — the player asked
// for overlays that behave, not for a description of how the app looks at the OS.
//
// HIDE, NEVER CLOSE, and the copy says so: an auto-hidden overlay keeps its position, its lock and
// its size, and its own switch on this page stays on. That is the difference between a setting and
// a surprise.
//
// "NOT IN EVERQUEST" INCLUDES THIS APP. The overlays themselves do not count — they are
// non-activating panels, so clicking one does not change which application is in front and an
// overlay cannot make itself vanish under your cursor.
import SwiftUI

extension PrefPages {
    static let overlays = PrefPage(id: "overlays", label: "Overlays", icon: "square.3.layers.3d", sections: [
        PrefSectionInfo(id: "overlay-autohide", label: "Hide overlays automatically",
                        keywords: "hide overlay overlays game running closed focus focused alt-tab away desktop"),
        PrefSectionInfo(id: "toast", label: "Celebration toasts",
                        keywords: "toast celebration boss kill raid target sky quest complete congratulate card"),
        PrefSectionInfo(id: "alert-banner", label: "Alert banner",
                        keywords: "alert alerts banner strip on screen lines big text warning fade"),
        PrefSectionInfo(id: "con-card", label: "Mob card on con",
                        keywords: "con consider mob card creature level resist popup"),
        PrefSectionInfo(id: "overlay-background", label: "Overlay background",
                        keywords: "solid background opaque see-through transparent black box artifact")
    ]) { AnyView(OverlaysPage()) }
}

struct OverlaysPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AutoHideCard()
            ToastCard()
            AlertBannerCard()
            ConCardCard()
            OverlayBackgroundCard()
        }
    }
}

/// Two independent switches over one question: when should the floating windows get out of the way?
/// They are deliberately NOT one three-state mode — "don't leave meters over my desktop when I'm not
/// playing" is housekeeping almost everyone wants, while "vanish every time I alt-tab" is a taste
/// many people actively don't share (you alt-tab TO read the numbers).
private struct AutoHideCard: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        PrefCard("Hide overlays automatically") {
            PrefToggle(label: "Hide overlays when EverQuest isn’t running",
                       isOn: $prefs.hideOverlaysWhenGameClosed,
                       captionOn: "Your open overlays disappear while the game is closed and come back when it starts. They keep their position, size and lock - nothing is closed.",
                       captionOff: "Off. Open overlays stay on screen whether or not the game is running.")
            PrefToggle(label: "Hide overlays when you’re not in EverQuest",
                       isOn: $prefs.hideOverlaysWhenGameUnfocused,
                       captionOn: "Your open overlays disappear whenever anything else is in front - including this app’s own window, so they’re out of the way while you browse it. Clicking an overlay itself keeps them up.",
                       captionOff: "Off. Open overlays stay on screen while you work in other apps.")
        }
    }
}

private struct ToastCard: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        PrefCard("Celebration toasts") {
            VStack(alignment: .leading, spacing: 4) {
                // THE MAC CARD IS NOT A CLICK TARGET. A locked strip passes clicks straight to the
                // game, so it cannot also open a tab — the upstream clause promising that is gone.
                PrefToggle(label: "Celebrate boss kills and Sky quests on screen",
                           isOn: $prefs.toastsEnabled,
                           captionOn: "A card slides in at the top of the screen when you drop a raid target or finish a Plane of Sky quest, then fades. Point at it to keep it up.",
                           captionOff: "Off. Boss kills and quest completions still show up in the app and in your alerts - nothing appears over the game.")
                // The strip has no controls of its own, so this says where its size lives.
                PrefCaption("Its text size and transparency are Appearance → Overlays.")
            }
            PrefToggle(label: "Move it", isOn: $prefs.toastsMovable,
                       captionOn: "The strip is showing its outline - drag it anywhere. Turn this off when it sits where you want it.",
                       captionOff: "The strip sits where you left it and clicks pass straight through to the game.")
                .disabled(!prefs.toastsEnabled)
        }
    }
}

private struct AlertBannerCard: View {
    @Bindable private var prefs = Prefs.shared

    /// A closed list, not a slider: the difference between 4 s and 4.3 s is not a decision anybody
    /// has.
    private let holds = [2, 4, 6, 8, 10]
    /// How many lines may share the strip. Beyond a handful it stops being a glance.
    private let lines = Array(1...8)

    var body: some View {
        PrefCard("Alert banner") {
            VStack(alignment: .leading, spacing: 4) {
                PrefToggle(label: "Show alerts on screen", isOn: $prefs.bannerEnabled,
                           captionOn: "Alerts marked Show on screen appear as large text over the game, then fade. Point at the strip to keep it up. Each alert says whether it appears here, in the Alerts tab.",
                           captionOff: "Off. Your alerts still play their sound and speak - nothing appears over the game.")
                PrefCaption("Its text size and transparency are Appearance → Overlays.")
            }
            PrefToggle(label: "Move it", isOn: $prefs.bannerMovable,
                       captionOn: "The strip is showing its outline - drag it anywhere. Turn this off when it sits where you want it.",
                       captionOff: "The strip sits where you left it and clicks pass straight through to the game.")
                .disabled(!prefs.bannerEnabled)
            HStack(alignment: .top, spacing: 24) {
                PrefSelect(label: "A line stays for", selection: $prefs.bannerLineSeconds,
                           options: holds.map { ($0, "\($0) seconds") })
                    .disabled(!prefs.bannerEnabled)
                PrefSelect(label: "Lines on screen at once", selection: $prefs.bannerLines,
                           options: lines.map { ($0, "\($0)") })
                    .disabled(!prefs.bannerEnabled)
            }
            PrefCaption("The newest alert sits at the bottom; when the strip is full the oldest one leaves.")
        }
    }
}

private struct ConCardCard: View {
    @Bindable private var prefs = Prefs.shared

    private let holds = [2, 3, 5, 8, 12]

    var body: some View {
        PrefCard("Mob card on con") {
            VStack(alignment: .leading, spacing: 4) {
                // THE MAC CARD DOES NOT OPEN THE MOB PAGE. The upstream card is a click target into
                // the app's mob view; nothing here can address one creature in the Mobs tab yet, so
                // the sentence that promised it is not in this caption.
                PrefToggle(label: "Show a mob card when you con", isOn: $prefs.conCardEnabled,
                           captionOn: "Con a creature and a card appears over the game with its level and what your logs know about its resists. The next con replaces it, and it goes on its own.",
                           captionOff: "Off. Conning a creature does nothing over the game - the mobs you con are still listed on the Overview.")
                PrefCaption("Its text size and transparency are Appearance → Overlays.")
            }
            PrefToggle(label: "Move it", isOn: $prefs.conCardMovable,
                       captionOn: "The card area is showing its outline - drag it anywhere. Turn this off when it sits where you want it.",
                       captionOff: "The card sits where you left it and clicks pass straight through to the game.")
                .disabled(!prefs.conCardEnabled)
            PrefSelect(label: "A card stays for", selection: $prefs.conCardSeconds,
                       options: holds.map { ($0, "\($0) seconds") })
                .disabled(!prefs.conCardEnabled)
        }
    }
}

/// The one half of the upstream Graphics page that exists on a Mac. Its other switch — draw without
/// the graphics card — is a Chromium flag the Electron app sets for Wine, and there is no such knob
/// here.
///
/// IT APPLIES AT ONCE, unlike the Windows one: these panels read the setting every time they draw,
/// so nothing has to be reopened.
private struct OverlayBackgroundCard: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        PrefCard("Overlay background") {
            PrefToggle(label: "Give floating overlays a solid background",
                       isOn: $prefs.overlaySolidBackground,
                       captionOn: "On. Same meters, same colours, no see-through — the transparency in Appearance → Overlays is not in force while this is on.",
                       captionOff: "Off. Overlays float see-through over the game. Turn this on if they go black or leave marks on screen.")
        }
    }
}
