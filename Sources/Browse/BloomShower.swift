import SwiftUI

/// The hidden extra on Home (pull far down): petals in the accent colour drift down past a short
/// message, then it all goes away. It never takes taps.
struct BloomShower: View {
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var petals = (0..<40).map { Petal(id: $0) }
    @State private var falling = false
    @State private var showMessage = false

    private struct Petal: Identifiable {
        let id: Int
        let x = Double.random(in: 0...1)
        let drift = Double.random(in: -70...70)
        let size = Double.random(in: 12...24)
        let spin = Double.random(in: -300...300)
        let delay = Double.random(in: 0...1.4)
        let duration = Double.random(in: 2.2...3.4)
        let opacity = Double.random(in: 0.55...1)
    }

    var body: some View {
        GeometryReader { screen in
            ZStack {
                if !reduceMotion {
                    ForEach(petals) { petal in
                        PetalShape()
                            .fill(Theme.accent.opacity(petal.opacity))
                            .frame(width: petal.size * 0.7, height: petal.size)
                            .rotationEffect(.degrees(falling ? petal.spin : 0))
                            .position(x: petal.x * screen.size.width + (falling ? petal.drift : 0),
                                      y: falling ? screen.size.height + 40 : -40)
                            .animation(.easeIn(duration: petal.duration).delay(petal.delay), value: falling)
                    }
                }
                if showMessage {
                    VStack(spacing: 6) {
                        Text("You found the bloom")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("Made with care by Bloom. Enjoy the show.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text2)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.raised2))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                    .padding(.horizontal, 24)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(width: screen.size.width, height: screen.size.height)
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.success, trigger: showMessage) { _, shown in shown }
        .task {
            falling = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { showMessage = true }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.5)) { showMessage = false }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            done()
        }
    }
}

/// A teardrop petal, pointed at the bottom.
private struct PetalShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tip = CGPoint(x: rect.midX, y: rect.maxY)
        path.move(to: tip)
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.minX - rect.width * 0.2, y: rect.height * 0.6),
                      control2: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(to: tip,
                      control1: CGPoint(x: rect.maxX, y: rect.minY),
                      control2: CGPoint(x: rect.maxX + rect.width * 0.2, y: rect.height * 0.6))
        return path
    }
}
