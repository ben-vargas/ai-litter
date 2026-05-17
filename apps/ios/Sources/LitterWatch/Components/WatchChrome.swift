import SwiftUI

/// Themed eyebrow heading — small uppercased mono text. When `color` is nil
/// it falls back to the live `WatchThemeStore` accent so unstyled callers
/// inherit the user's selected theme.
struct WatchEyebrow: View {
    @EnvironmentObject var theme: WatchThemeStore
    let text: String
    var color: Color? = nil
    var size: CGFloat = 11

    var body: some View {
        Text(text.uppercased())
            .font(WatchTheme.mono(size, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(color ?? theme.accent)
    }
}

/// Pulsing dot used to signal activity.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.9), radius: pulse ? 5 : 2)
            .scaleEffect(pulse ? 1.15 : 1)
            .animation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

/// Centered empty-state card. Used when the watch has no data for a
/// surface yet — either no pending approval, no running task, etc.
struct WatchEmptyState: View {
    @EnvironmentObject var theme: WatchThemeStore
    let icon: String
    let title: String
    let subtitle: String?

    init(icon: String, title: String, subtitle: String? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(theme.textSecondary)
            Text(title)
                .font(WatchTheme.mono(12, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(WatchTheme.mono(10))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }
}
