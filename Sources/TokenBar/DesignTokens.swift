import SwiftUI

/// Shared layout/typography constants so cards, spacing, and text sizes stop
/// drifting independently across the dashboard. Values are chosen to match
/// what was already the most common size at each call site, not invented
/// from scratch.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 14
    static let lg: CGFloat = 18
}

enum Motion {
    static let standard = Animation.easeInOut(duration: 0.18)
}

enum Typography {
    static let hero = Font.system(size: 40, weight: .bold, design: .rounded)
    static let title = Font.system(size: 18, weight: .bold)
    static let sectionHeader = Font.system(size: 14, weight: .semibold)
    static let statValue = Font.system(size: 22, weight: .bold, design: .rounded)
    static let body = Font.system(size: 13, weight: .medium)
    static let caption = Font.caption
    static let caption2 = Font.caption2
}

/// Every card on the dashboard uses the same material, corner radius, and
/// hairline border; this used to be copy-pasted at five separate call sites.
/// A soft, low contact shadow gives cards a touch of native-feeling depth
/// against the window background instead of sitting perfectly flat.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

/// A row of window-range pills (今日/24h/3D/…), reused by both the dashboard's
/// main window selector and the trend section's independent range picker -
/// so the two don't have to be kept in sync manually.
struct WindowPillRow: View {
    let current: DisplayWindow
    var compact: Bool = false
    let onSelect: (DisplayWindow) -> Void

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(DisplayWindow.allCases) { w in
                let isActive = w == current
                Button {
                    onSelect(w)
                } label: {
                    Text(w.shortName)
                        .font(.system(size: compact ? 10 : 12, weight: .semibold))
                        .padding(.horizontal, compact ? 7 : 11)
                        .padding(.vertical, compact ? 3 : 6)
                        .background(
                            Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.10))
                        )
                        .foregroundStyle(isActive ? Color.white : Color.primary)
                        .overlay(
                            Capsule().stroke(isActive ? Color.clear : Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Shows a tool's real product icon (its actual app icon) at the given size,
/// falling back to a generic SF Symbol only if the bundled asset is missing.
/// The real icons already come as fully-styled rounded-square app icons, so
/// this just clips them to match - no extra tinted background needed.
struct ToolIconView: View {
    let tool: ToolKind
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = tool.productIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(tool.tintColor.opacity(0.15))
                    Image(systemName: tool.systemImage)
                        .foregroundStyle(tool.tintColor)
                        .font(.system(size: size * 0.4, weight: .bold))
                }
            }
        }
        .frame(width: size, height: size)
    }
}
