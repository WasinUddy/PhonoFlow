//
//  PhaseScopeView.swift
//  PhonoFlow
//
//  Lissajous figure (X-Y plot) showing stereo phase relationship.
//

import SwiftUI

struct PhaseScopeView: View {
    var points: [(x: Float, y: Float)]
    var theme: ColorTheme
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                vizInfoButton(
                    title: "PHASE SCOPE",
                    showInfo: $showInfo,
                    tips: [
                        "Vertical line = mono (L and R identical)",
                        "Circle/blob = wide stereo image",
                        "Horizontal line = one channel missing",
                        "Leaning left/right = off-center stereo",
                        "Random scatter = phase issues or inverted wiring",
                    ]
                )
                Spacer()
            }
            .padding(.bottom, 4)

            Canvas { context, size in
                let side = min(size.width, size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = side / 2 - 8

                // Draw cross-hair guides
                context.opacity = 0.15
                var centerLineV = Path()
                centerLineV.move(to: CGPoint(x: center.x, y: 0))
                centerLineV.addLine(to: CGPoint(x: center.x, y: size.height))
                context.stroke(centerLineV, with: .color(.primary), lineWidth: 0.5)

                var centerLineH = Path()
                centerLineH.move(to: CGPoint(x: 0, y: center.y))
                centerLineH.addLine(to: CGPoint(x: size.width, y: center.y))
                context.stroke(centerLineH, with: .color(.primary), lineWidth: 0.5)

                // Draw reference circles
                context.opacity = 0.08
                for scale in [0.5, 1.0] {
                    let r = radius * scale
                    let circle = Path(ellipseIn: CGRect(
                        x: center.x - r,
                        y: center.y - r,
                        width: r * 2,
                        height: r * 2
                    ))
                    context.stroke(circle, with: .color(.primary), lineWidth: 0.5)
                }

                // Draw Lissajous curve
                context.opacity = 1.0
                guard points.count > 1 else { return }

                var path = Path()
                for (index, point) in points.enumerated() {
                    let x = center.x + CGFloat(point.x) * radius * 0.9
                    let y = center.y - CGFloat(point.y) * radius * 0.9

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                let gradient = Gradient(colors: [
                    theme.accent.opacity(0.4),
                    theme.accent
                ])
                context.stroke(path, with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: size.height)
                ), lineWidth: 1.8)
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(6)
        }
    }
}
