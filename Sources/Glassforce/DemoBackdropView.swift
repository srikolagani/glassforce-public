import SwiftUI

/// Calm desktop behind glass for `--backdrop` screenshots. Enough luminance variation
/// that Liquid Glass reads as glass, without a rainbow mesh or a white void.
struct DemoBackdropView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.34, blue: 0.44),
                    Color(red: 0.40, green: 0.46, blue: 0.56),
                    Color(red: 0.22, green: 0.26, blue: 0.34),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Soft window of light — glass should catch this.
            Ellipse()
                .fill(.white.opacity(0.35))
                .frame(width: 900, height: 520)
                .blur(radius: 90)
                .offset(x: -120, y: -200)
            Ellipse()
                .fill(Color(red: 0.55, green: 0.70, blue: 0.90).opacity(0.40))
                .frame(width: 700, height: 480)
                .blur(radius: 80)
                .offset(x: 260, y: 180)
            // Gentle horizon band
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 180)
                .offset(y: -40)
        }
        .ignoresSafeArea()
    }
}
