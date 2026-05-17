import SwiftUI
import WatchKit
import UserNotifications

/// Identifiers shared with the iPhone notification scheduler. Keep in lock
/// step with `WatchApprovalNotification` on the iOS target — copied here so
/// the watch target doesn't need to link the iOS module.
enum WatchApprovalNotificationConstants {
    static let categoryIdentifier = "litter.approval"
    static let allowActionIdentifier = "litter.approval.allow"
    static let denyActionIdentifier = "litter.approval.deny"
    static let requestIdKey = "requestId"
}

/// Pure routing of a notification response action id to an approval
/// decision. Exposed so unit tests can validate the dispatch table without
/// instantiating UserNotifications types.
enum WatchApprovalActionRouter {
    enum Decision: Equatable {
        case approve(requestId: String)
        case deny(requestId: String)
        case noop
    }

    static func decision(
        forActionIdentifier actionId: String,
        userInfo: [AnyHashable: Any]
    ) -> Decision {
        guard let requestId = userInfo[WatchApprovalNotificationConstants.requestIdKey] as? String,
              !requestId.isEmpty else {
            return .noop
        }
        switch actionId {
        case WatchApprovalNotificationConstants.allowActionIdentifier:
            return .approve(requestId: requestId)
        case WatchApprovalNotificationConstants.denyActionIdentifier:
            return .deny(requestId: requestId)
        default:
            return .noop
        }
    }
}

/// Routes notification action taps from the system into
/// `WatchSessionBridge.shared.sendApprovalDecision`. Owned by
/// `LitterWatchApp` so the singleton survives the whole app lifetime.
final class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationDelegate()
    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let decision = WatchApprovalActionRouter.decision(
            forActionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        switch decision {
        case .approve(let requestId):
            Task { @MainActor in
                WatchSessionBridge.shared.sendApprovalDecision(
                    requestId: requestId,
                    approve: true
                )
                completionHandler()
            }
        case .deny(let requestId):
            Task { @MainActor in
                WatchSessionBridge.shared.sendApprovalDecision(
                    requestId: requestId,
                    approve: false
                )
                completionHandler()
            }
        case .noop:
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

/// Root @main for the Litter Watch app. Vertically paginated TabView
/// makes the three hero surfaces reachable via crown/swipe.
@main
struct LitterWatchApp: App {
    @StateObject private var store = WatchAppStore.shared
    @StateObject private var theme = WatchThemeStore.shared

    init() {
        WatchSessionBridge.shared.start()
        registerNotificationCategories()
    }

    private func registerNotificationCategories() {
        let center = UNUserNotificationCenter.current()
        center.delegate = WatchNotificationDelegate.shared
        let approval = UNNotificationCategory(
            identifier: WatchApprovalNotificationConstants.categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: WatchApprovalNotificationConstants.allowActionIdentifier,
                    title: "Allow",
                    options: []
                ),
                UNNotificationAction(
                    identifier: WatchApprovalNotificationConstants.denyActionIdentifier,
                    title: "Deny",
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([approval])
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
                .environmentObject(theme)
                .environment(\.watchSize, WatchSize.current)
                .preferredColorScheme(theme.colorScheme)
                .tint(theme.accent)
        }

        WKNotificationScene(
            controller: LitterNotificationController.self,
            category: "litter.task.complete"
        )

        WKNotificationScene(
            controller: LitterNotificationController.self,
            category: WatchApprovalNotificationConstants.categoryIdentifier
        )
    }
}

/// The three-page hero loop: glance → dictate → approve.
///
/// A single root `NavigationStack` wraps the `TabView` so pushed
/// destinations (task detail, transcript, approval) replace the whole
/// pager and the native horizontal edge-swipe-back gesture works.
/// Nesting `NavigationStack` per tab page fought with the vertical
/// page tab view and broke back navigation.
struct WatchRootView: View {
    @EnvironmentObject var store: WatchAppStore
    @State private var tab: RootTab = .home
    @State private var path: [WatchTask] = []

    var body: some View {
        NavigationStack(path: $path) {
            TabView(selection: $tab) {
                HomeScreen().tag(RootTab.home)
                RealtimeVoiceScreen().tag(RootTab.voice)
                ApprovalScreen().tag(RootTab.approval)
            }
            .tabViewStyle(.verticalPage)
            .navigationDestination(for: WatchTask.self) { task in
                TaskDetailScreen(task: task)
            }
        }
        .onOpenURL { url in
            route(url)
        }
    }

    /// Parse `litter-watch://task/{taskId}` and push `TaskDetailScreen` for
    /// the matched task. Falls back to home when the task isn't in the
    /// store (e.g., complication tapped before first snapshot arrived).
    private func route(_ url: URL) {
        guard url.scheme == "litter-watch", url.host == "task" else { return }
        let taskId = url.pathComponents.dropFirst().first ?? ""
        guard !taskId.isEmpty,
              let task = store.tasks.first(where: { $0.id == taskId })
        else {
            path.removeAll()
            tab = .home
            return
        }
        tab = .home
        path = [task]
    }
}

enum RootTab: Hashable {
    case home, voice, approval
}

final class LitterNotificationController: WKUserNotificationHostingController<NotificationScreen> {
    private var currentNotification: UNNotification?

    override var body: NotificationScreen {
        NotificationScreen(notification: currentNotification)
    }

    override func didReceive(_ notification: UNNotification) {
        currentNotification = notification
    }
}
