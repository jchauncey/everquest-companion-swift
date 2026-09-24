// A scroll area as tall as its content up to a cap: the long lists on the Leveling tab scroll inside
// their panels instead of stretching the page.
import SwiftUI

/// A scroll area as tall as its content up to `maxHeight`, and scrolling past it: a short list
/// takes its own height, a long one stops growing the page.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        }
        .frame(height: min(max(height, 1), maxHeight))
    }
}
