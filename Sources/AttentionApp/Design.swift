import SwiftUI
import AppKit

enum Design {
    static let amber = adaptive(light: (0.65, 0.34, 0.05), dark: (0.94, 0.67, 0.34))
    static let green = adaptive(light: (0.12, 0.43, 0.32), dark: (0.42, 0.75, 0.60))
    static let blue = adaptive(light: (0.20, 0.38, 0.62), dark: (0.47, 0.67, 0.90))
    static let purple = adaptive(light: (0.47, 0.32, 0.67), dark: (0.72, 0.60, 0.91))
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.075)
    static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
}

struct RouterMark: View {
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(Design.amber.opacity(0.12))
            Circle().stroke(Design.amber.opacity(0.30), lineWidth: 1.3).padding(size * 0.23)
            Circle().fill(Design.amber).frame(width: size * 0.16, height: size * 0.16)
            Circle().fill(Design.amber).frame(width: size * 0.13, height: size * 0.13).offset(x: size * 0.20, y: -size * 0.20)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct SectionCaption: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("\(count)").font(.system(size: 10, weight: .semibold, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 2).background(.primary.opacity(0.06), in: Capsule())
            Spacer()
        }.foregroundStyle(.secondary).padding(.horizontal, 2)
    }
}

struct IconButton: View {
    let icon: String
    let label: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 13)).frame(width: 28, height: 28).background(.primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label).onHover { hovering = $0 }
    }
}
