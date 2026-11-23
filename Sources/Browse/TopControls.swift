import SwiftUI

extension View {
    /// Round buttons floating over a page's top corners, a little lower than the system bar puts them.
    /// Used by pages whose backdrop runs under the (hidden) navigation bar.
    func topControls<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let left = leading()
        let right = trailing()
        return overlay(alignment: .top) {
            GeometryReader { proxy in
                HStack(spacing: 10) {
                    left
                    Spacer(minLength: 0)
                    right
                }
                .padding(.horizontal, 16)
                // 47 is the notch height, used if the real inset reads as zero.
                .padding(.top, max(proxy.safeAreaInsets.top, 47) + 12)
            }
        }
    }
}
