import SwiftUI
import UIKit

/// Sizes that grow a little on iPad. On iPhone everything is exactly as designed.
enum Metrics {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let scale: CGFloat = isPad ? 1.3 : 1
}

extension View {
    /// Keeps text-heavy pages from stretching across a wide iPad screen. No effect on iPhone.
    func readableWidth(_ width: CGFloat = 820) -> some View {
        frame(maxWidth: width, alignment: .leading).frame(maxWidth: .infinity)
    }
}
