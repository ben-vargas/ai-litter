import SwiftUI
import WatchKit

/// 1 · Task list — the watch's equivalent of the iPhone sessions screen.
/// Each row mirrors `SessionCanvasLine` at GLANCE density: status dot,
/// title + age, identity strip (server · model · cwd), status-colored
/// subtitle, and an optional telemetry chip line for running tasks.
struct HomeScreen: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        Group {
            if !store.hasData {
                WatchEmptyState(
                    icon: "iphone.gen3",
                    title: store.isReachable ? "syncing…" : "open litter on iphone",
                    subtitle: store.isReachable ? nil : "the watch shows what the phone knows."
                )
            } else if store.tasks.isEmpty {
                WatchEmptyState(
                    icon: "sparkles",
                    title: "no tasks yet",
                    subtitle: "start a conversation on iphone."
                )
            } else {
                List {
                    if store.lastSyncIsStale && !store.isReachable {
                        Section {
                            HStack(spacing: 6) {
                                Image(systemName: "iphone.slash")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(theme.textSecondary)
                                Text("phone unreachable · last-known")
                                    .font(WatchTheme.mono(9))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }

                    Section {
                        ForEach(store.tasks) { task in
                            NavigationLink {
                                TaskDetailScreen(task: task)
                            } label: {
                                TaskRow(task: task)
                            }
                            .listItemTint(task.status == .running
                                          ? theme.accent
                                          : theme.borderHi)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    WKInterfaceDevice.current().play(.click)
                                    WatchSessionBridge.shared.sendHomeHide(
                                        serverId: task.serverId,
                                        threadId: task.threadId
                                    )
                                } label: {
                                    Label("Hide", systemImage: "eye.slash")
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            WatchEyebrow(text: "tasks", color: theme.accent, size: 10)
                            Spacer()
                            HeaderBadges()
                        }
                    }

                    Section {
                        NavigationLink {
                            VoiceScreen()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(theme.accent)
                                Text("new task")
                                    .font(WatchTheme.mono(12, weight: .bold))
                                    .foregroundStyle(theme.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.carousel)
            }
        }
        .containerBackground(theme.backgroundGradient, for: .navigation)
    }
}

private struct HeaderBadges: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        HStack(spacing: 6) {
            if store.approvalsTaskCount > 0 {
                Badge(color: theme.warning, count: store.approvalsTaskCount)
            }
            if store.runningTaskCount > 0 {
                Badge(color: theme.success, count: store.runningTaskCount)
            }
        }
    }
}

private struct Badge: View {
    @EnvironmentObject var theme: WatchThemeStore
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)")
                .font(WatchTheme.mono(10))
                .foregroundStyle(theme.textSecondary)
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject var theme: WatchThemeStore
    let task: WatchTask

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusBullet(status: task.status)
                .frame(width: 10, height: 10)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                // Row 1: title + right-aligned age chip.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.title)
                        .font(WatchTheme.mono(13, weight: .bold))
                        .foregroundStyle(task.status == .running ? theme.accent : theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if !task.relativeTime.isEmpty {
                        Text(task.relativeTime)
                            .font(WatchTheme.mono(10))
                            .foregroundStyle(theme.textMuted)
                            .fixedSize()
                    }
                }

                // Row 2: identity strip — server · model · cwd-basename.
                identityStrip

                // Row 3: subtitle (last activity), color-coded by status.
                if let subtitle = task.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(WatchTheme.mono(10))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                // Row 4: compact telemetry — only when running and at least
                // one field is non-zero. Keeps idle rows clean.
                if task.status == .running, let line = telemetryLine {
                    Text(line)
                        .font(WatchTheme.mono(9))
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var identityStrip: some View {
        HStack(spacing: 4) {
            Text(task.serverName)
                .foregroundStyle(theme.accent.opacity(0.7))
                .lineLimit(1)
            if let model = task.model, !model.isEmpty {
                dot
                Text(model)
                    .foregroundStyle(theme.textSecondary.opacity(0.85))
                    .lineLimit(1)
            }
            if let basename = cwdBasename {
                dot
                Text(basename)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(WatchTheme.mono(10))
    }

    private var dot: some View {
        Text("·").foregroundStyle(theme.textMuted.opacity(0.6))
    }

    private var cwdBasename: String? {
        guard let cwd = task.cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    private var subtitleColor: Color {
        switch task.status {
        case .running:       return theme.accent
        case .needsApproval: return theme.warning
        case .idle:          return theme.textMuted
        case .error:         return theme.danger
        }
    }

    private var telemetryLine: String? {
        var parts: [String] = []
        if let t = task.turnCount, t > 0 { parts.append("\(t) turns") }
        let adds = task.diffAdditions ?? 0
        let rems = task.diffDeletions ?? 0
        if adds > 0 || rems > 0 { parts.append("+\(adds) −\(rems)") }
        if let pct = task.contextPercent, pct > 0 { parts.append("\(pct)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct StatusBullet: View {
    @EnvironmentObject var theme: WatchThemeStore
    let status: WatchTask.Status

    var body: some View {
        switch status {
        case .running:
            PulsingDot(color: theme.accent, size: 8)
        case .needsApproval:
            ZStack {
                Circle().fill(theme.warning.opacity(0.25))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(theme.warning)
            }
        case .idle:
            Circle().fill(theme.textSecondary).frame(width: 6, height: 6)
        case .error:
            Circle().fill(theme.danger).frame(width: 6, height: 6)
        }
    }
}

#if DEBUG
#Preview("tasks") {
    NavigationStack {
        HomeScreen()
            .environmentObject(WatchAppStore.previewStore())
            .environmentObject(WatchThemeStore.shared)
    }
}

#Preview("empty") {
    NavigationStack {
        HomeScreen()
            .environmentObject(WatchAppStore())
            .environmentObject(WatchThemeStore.shared)
    }
}
#endif
