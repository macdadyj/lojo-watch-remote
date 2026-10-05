import SwiftUI
#if os(iOS)
import UIKit
#endif

public enum LojoTheme {
    public static let accent = Color(red: 15.0 / 255, green: 140.0 / 255, blue: 148.0 / 255)
    public static let accentDeep = Color(red: 38.0 / 255, green: 46.0 / 255, blue: 120.0 / 255)
    public static let online = Color(red: 0.16, green: 0.72, blue: 0.45)
    public static let warning = Color(red: 0.95, green: 0.62, blue: 0.10)
    public static let danger = Color(red: 0.90, green: 0.27, blue: 0.25)
    /// Dark enough that white label text stays readable on both appearances.
    public static let dangerFill = Color(red: 0.70, green: 0.15, blue: 0.13)
    public static let cornerRadius: CGFloat = 18
    public static let hairline = Color.primary.opacity(0.06)

    public static let brandGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static var cardBackground: Color {
        #if os(watchOS)
        Color.white.opacity(0.08)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    public static var pageBackground: Color {
        #if os(watchOS)
        Color.black
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    #if os(watchOS)
    public static let control = Color(red: 0.56, green: 0.61, blue: 0.96)
    #else
    public static let control = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.56, green: 0.61, blue: 0.96, alpha: 1)
            : UIColor(red: 0.15, green: 0.18, blue: 0.47, alpha: 1)
    })
    #endif
}

public enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "Match device"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension LojoTheme {
    public static func readablePrimary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .light: return .black
        case .dark: return .white
        @unknown default: return .white
        }
    }

    public static func readableSecondary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .light: return Color.black.opacity(0.70)
        case .dark: return Color.white.opacity(0.82)
        @unknown default: return Color.white.opacity(0.82)
        }
    }

    /// Secondary copy on the iPhone. System gray sits too low on grouped backgrounds.
    public static let secondaryText = Color.primary.opacity(0.70)
}

public struct CardModifier: ViewModifier {
    var padding: CGFloat
    @Environment(\.colorScheme) private var scheme

    public init(padding: CGFloat = 16) {
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LojoTheme.cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LojoTheme.cornerRadius, style: .continuous)
                    .strokeBorder(LojoTheme.hairline)
            )
    }

    private var fill: Color {
        #if os(watchOS)
        switch scheme {
        case .light: return Color.black.opacity(0.06)
        case .dark: return Color.white.opacity(0.10)
        @unknown default: return Color.white.opacity(0.10)
        }
        #else
        LojoTheme.cardBackground
        #endif
    }
}

extension View {
    public func lojoCard(padding: CGFloat = 16) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

public struct StatusMark: View {
    public var status: SessionStatus
    public var size: CGFloat

    public init(status: SessionStatus, size: CGFloat = 12) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        mark
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        switch status {
        case .running:
            Circle().fill(LojoTheme.accent)
        case .needsApproval:
            Rectangle()
                .fill(LojoTheme.warning)
                .rotationEffect(.degrees(45))
                .padding(size * 0.18)
        case .idle:
            Circle().strokeBorder(Color.primary.opacity(0.70), lineWidth: 1.5)
        case .stopped:
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.70), lineWidth: 1.5)
        case .failed:
            Triangle().stroke(LojoTheme.danger, lineWidth: 1.5)
        case .unknown:
            Circle().trim(from: 0.5, to: 1).stroke(LojoTheme.warning, lineWidth: 1.5)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

public struct IconTile: View {
    public var systemImage: String
    public var active: Bool
    public var size: CGFloat

    public init(systemImage: String, active: Bool = true, size: CGFloat = 44) {
        self.systemImage = systemImage
        self.active = active
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(active ? AnyShapeStyle(LojoTheme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.secondary)
            )
            .accessibilityHidden(true)
    }
}

public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact: Bool

    var prominent: Bool

    public init(compact: Bool = false, prominent: Bool = false) {
        self.compact = compact
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? .title3.weight(.semibold) : (compact ? .footnote.weight(.semibold) : .body.weight(.semibold)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, prominent ? 18 : (compact ? 6 : 14))
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(LojoTheme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

public struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .footnote.weight(.semibold) : .body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 6 : 13)
            .foregroundStyle(Color.primary)
            .background(
                RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                    .fill(Color.primary.opacity(scheme == .dark ? 0.18 : 0.08))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

public struct DestructiveButtonStyle: ButtonStyle {
    var compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .footnote.weight(.semibold) : .body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 6 : 13)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                    .fill(LojoTheme.dangerFill)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

public struct DemoBadge: View {
    var compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public var body: some View {
        Text("DEMO")
            .font(compact ? .system(size: 9, weight: .heavy) : .caption2.weight(.heavy))
            .tracking(compact ? 0.6 : 1.2)
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 2 : 3)
            .foregroundStyle(.white)
            .background(Capsule().fill(LojoTheme.warning))
            .accessibilityLabel("Demo mode. Sample sessions, nothing is sent.")
    }
}
