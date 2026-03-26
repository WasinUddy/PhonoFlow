//
//  UIComponents.swift
//  PhonoFlow
//
//  Reusable UI components and styles
//

import SwiftUI

// MARK: - Glass Effect Container

struct GlassEffectContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Glass Button Style

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? .secondary : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
