import SwiftUI
import UIKit

struct TerminalScreen: View {
    let cwd: String?
    var preferredAlleycatNodeId: String? = nil

    @State private var controller = TerminalSessionController()
    @State private var backendOptions: [TerminalBackendOption] = []
    @State private var selectedBackendID: String?
    @State private var didStart = false
    @State private var terminalGridSize = TerminalGridSize(cols: 80, rows: 24)
    @State private var command = ""
    @State private var ghosttyRenderer = GhosttyTerminalRenderer()
    @State private var nativeRendererHasOutput = false
    @State private var showConfigSheet = false
    @AppStorage("litter.terminal.fontSize") private var storedFontSize: Double = 13.0
    @AppStorage("litter.terminal.themeId") private var storedThemeId: String = "litter-dark"
    @AppStorage("litter.terminal.cursorBlink") private var storedCursorBlink: Bool = true
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private let accent = Color(red: 0, green: 1, blue: 0.612)

    var body: some View {
        VStack(spacing: 0) {
            backendBar
            terminalOutput
            accessoryRow
            inputBar
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            guard !didStart else { return }
            didStart = true
            controller.setOutputSink { data in
                Task { @MainActor in
                    ghosttyRenderer.write(data)
                }
            }
            let options = loadBackendOptions(cwd: cwd)
            backendOptions = options
            let initial = initialBackend(from: options, cwd: cwd)
            selectedBackendID = initial.id
            await controller.open(backend: initial.backend)
            applyConfigSettings()
            inputFocused = true
        }
        .onDisappear {
            controller.setOutputSink(nil)
            ghosttyRenderer.invalidate()
            controller.close()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                ghosttyRenderer.setOccluded(false)
            case .inactive, .background:
                ghosttyRenderer.setOccluded(true)
            @unknown default:
                break
            }
        }
    }

    private var selectedBackend: TerminalBackendOption? {
        backendOptions.first { $0.id == selectedBackendID } ?? backendOptions.first
    }

    private var backendBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(backendOptions) { option in
                    Button {
                        selectBackend(option)
                    } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedBackend?.systemImage ?? "terminal")
                    Text(selectedBackend?.title ?? "Local iSH")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.custom("SFMono-Regular", size: 12))
                .foregroundColor(accent)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .disabled(backendOptions.count <= 1)

            Text(selectedBackend?.subtitle ?? "On device")
                .font(.custom("SFMono-Regular", size: 11))
                .foregroundColor(.white.opacity(0.48))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                showConfigSheet = true
            } label: {
                Text("Aa")
                    .font(.custom("SFMono-Regular", size: 13))
                    .foregroundColor(accent)
                    .frame(width: 34, height: 30)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("Theme and font")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .sheet(isPresented: $showConfigSheet) {
            TerminalConfigSheet(
                fontSize: $storedFontSize,
                themeId: $storedThemeId,
                cursorBlink: $storedCursorBlink,
                onApply: { applyConfigSettings() }
            )
        }
    }

    private var terminalOutput: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                GhosttyTerminalView(renderer: ghosttyRenderer, onNativeOutputVisibilityChanged: { visible in
                    nativeRendererHasOutput = visible
                }) { data in
                    Task {
                        await controller.send(data)
                    }
                }
                .background(Color.black)

                if shouldShowStatusOverlay {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(displayText)
                            .font(.custom("SFMono-Regular", size: 13))
                            .foregroundColor(phaseColor)
                            .textSelection(.enabled)
                        if let challenge = controller.sshTrustChallenge {
                            Button {
                                Task { await controller.trustUnknownSshHostAndRetry() }
                            } label: {
                                Label("Trust \(challenge.fingerprint)", systemImage: "key.fill")
                                    .font(.custom("SFMono-Regular", size: 12))
                                    .foregroundColor(.black)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .background(Color.black)
            .onAppear {
                resizeTerminal(for: geometry.size)
            }
            .onChange(of: geometry.size) { _, size in
                resizeTerminal(for: size)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: phaseIcon)
                .foregroundColor(phaseColor)
                .frame(width: 20)

            TextField("", text: $command, prompt: Text("Command").foregroundColor(.white.opacity(0.38)))
                .font(.custom("SFMono-Regular", size: 14))
                .foregroundColor(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($inputFocused)
                .submitLabel(.send)
                .disabled(!controller.canSendInput)
                .onSubmit { submitCommand() }

            Button(action: submitCommand) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(controller.canSendInput ? accent : .white.opacity(0.28))
            }
            .disabled(!controller.canSendInput)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
    }

    private var accessoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                terminalKey("Esc", enabled: controller.canSendInput) {
                    sendRaw("\u{1B}")
                }
                terminalKey("Tab", enabled: controller.canSendInput) {
                    sendRaw("\t")
                }
                terminalKey("Ctrl-C", enabled: controller.canSendInput) {
                    sendRaw("\u{03}")
                }
                terminalKey("Ctrl-D", enabled: controller.canSendInput) {
                    sendRaw("\u{04}")
                }
                terminalKey("Left", enabled: controller.canSendInput) {
                    sendRaw("\u{1B}[D")
                }
                terminalKey("Up", enabled: controller.canSendInput) {
                    sendRaw("\u{1B}[A")
                }
                terminalKey("Down", enabled: controller.canSendInput) {
                    sendRaw("\u{1B}[B")
                }
                terminalKey("Right", enabled: controller.canSendInput) {
                    sendRaw("\u{1B}[C")
                }
                terminalKey("Paste", enabled: controller.canSendInput && UIPasteboard.general.hasStrings) {
                    if let text = UIPasteboard.general.string {
                        sendRaw(text)
                    }
                }
                terminalKey("Clear", enabled: !controller.output.isEmpty) {
                    controller.clearOutput()
                    ghosttyRenderer.clearScreen()
                    nativeRendererHasOutput = false
                }
                terminalKey(
                    "Send to AI",
                    enabled: !controller.output.isEmpty && AppModel.shared.snapshot?.activeThread != nil
                ) {
                    sendOutputToAssistant()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color.black)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func terminalKey(
        _ label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.custom("SFMono-Regular", size: 12))
                .foregroundColor(enabled ? .white.opacity(0.78) : .white.opacity(0.28))
                .frame(minWidth: 34)
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(Color.white.opacity(enabled ? 0.08 : 0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var displayText: String {
        if !controller.output.isEmpty {
            return controller.output
        }
        switch controller.phase {
        case .idle, .connecting:
            return "Connecting...\n"
        case .running:
            return ""
        case .exited(let code):
            return "\n[process exited \(code)]\n"
        case .failed(let message):
            return "\n[terminal failed: \(message)]\n"
        }
    }

    private var shouldShowStatusOverlay: Bool {
        if !controller.output.isEmpty {
            return !nativeRendererHasOutput
        }
        switch controller.phase {
        case .idle, .connecting, .failed, .exited:
            return true
        case .running:
            return false
        }
    }

    private var phaseIcon: String {
        switch controller.phase {
        case .idle, .connecting: return "circle.dotted"
        case .running: return "terminal"
        case .exited: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .idle, .connecting: return .white.opacity(0.45)
        case .running: return accent
        case .exited: return .white.opacity(0.5)
        case .failed: return .red
        }
    }

    private func submitCommand() {
        guard controller.canSendInput else { return }
        let text = command
        command = ""
        Task {
            await controller.sendLine(text)
        }
    }

    private func sendRaw(_ text: String) {
        Task {
            await controller.send(text)
        }
    }

    /// Send the visible terminal output to the assistant on the current
    /// active thread, with cwd + last shell command pulled from the OSC
    /// semantic state. The painted-selection overlay isn't wired yet, so
    /// v1 sends the whole visible output. When the overlay lands this
    /// should switch to `renderer.sendSelectionToAssistant` and read from
    /// Ghostty's selection buffer.
    private func sendOutputToAssistant() {
        guard let threadKey = AppModel.shared.snapshot?.activeThread else { return }
        let text = controller.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            try? await ghosttyRenderer.sendTextToAssistant(
                store: AppModel.shared.store,
                threadKey: threadKey,
                selection: text
            )
        }
    }

    private func initialBackend(
        from options: [TerminalBackendOption],
        cwd: String?
    ) -> TerminalBackendOption {
        if let preferredNodeId = normalized(preferredAlleycatNodeId),
           let match = options.first(where: { $0.alleycatNodeId == preferredNodeId }) {
            return match
        }
        return options.first ?? TerminalBackendOption.localIsh(cwd: cwd)
    }

    private func selectBackend(_ option: TerminalBackendOption) {
        guard selectedBackendID != option.id else { return }
        selectedBackendID = option.id
        command = ""
        ghosttyRenderer.clearScreen()
        nativeRendererHasOutput = false
        Task {
            await controller.switchBackend(option.backend)
            inputFocused = true
        }
    }

    private func resizeTerminal(for size: CGSize) {
        let grid = TerminalGridSize(size: size)
        guard grid != terminalGridSize else { return }
        terminalGridSize = grid
        let notifyBackend = selectedBackend?.supportsResize == true
        Task {
            await controller.resize(cols: grid.cols, rows: grid.rows, notifyBackend: notifyBackend)
        }
    }

    private func loadBackendOptions(cwd: String?) -> [TerminalBackendOption] {
        var options = [TerminalBackendOption.localIsh(cwd: cwd)]
        var seenNodeIds = Set<String>()
        var seenSshKeys = Set<String>()
        for saved in SavedServerStore.rememberedServers() {
            if let nodeId = normalized(saved.alleycatNodeId),
               seenNodeIds.insert(nodeId).inserted,
               let token = try? AlleycatCredentialStore.shared.loadToken(nodeId: nodeId),
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                options.append(
                    TerminalBackendOption.remoteAlleycat(
                        name: saved.name,
                        nodeId: nodeId,
                        token: token,
                        relay: normalized(saved.alleycatRelay)
                    )
                )
                continue
            }

            let host = saved.hostname
            let sshPort = saved.sshPort ?? 22
            let sshKey = "\(host.lowercased()):\(sshPort)"
            guard !host.isEmpty, seenSshKeys.insert(sshKey).inserted else { continue }
            guard let credential = (try? SSHCredentialStore.shared.load(host: host, port: Int(sshPort))) ?? nil,
                  let sshAuth = Self.terminalSshAuth(from: credential) else {
                continue
            }
            options.append(
                TerminalBackendOption.remoteSsh(
                    name: saved.name,
                    host: host,
                    port: sshPort,
                    username: credential.username,
                    auth: sshAuth
                )
            )
        }
        return options
    }

    private static func terminalSshAuth(from credential: SavedSSHCredential) -> TerminalSshAuth? {
        switch credential.method {
        case .password:
            guard let password = credential.password, !password.isEmpty else { return nil }
            return .password(password: password)
        case .key:
            guard let key = credential.privateKey, !key.isEmpty else { return nil }
            return .privateKey(keyPem: key, passphrase: credential.passphrase)
        }
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyConfigSettings() {
        let config = TerminalConfig(
            theme: TerminalThemeChoice.preset(forId: storedThemeId),
            fontFamily: "SFMono-Regular",
            fontSizePt: Float(storedFontSize),
            cursorStyle: .bar,
            cursorBlink: storedCursorBlink,
            scrollbackLines: 10_000
        )
        ghosttyRenderer.applyConfig(config)
    }
}

private enum TerminalThemeChoice: String, CaseIterable, Identifiable {
    case litterDark = "litter-dark"
    case catppuccinFrappe = "catppuccin-frappe"
    case catppuccinFrappeLight = "catppuccin-frappe-light"
    case solarizedDark = "solarized-dark"
    case solarizedLight = "solarized-light"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .litterDark: return "Litter Dark"
        case .catppuccinFrappe: return "Catppuccin Frappé"
        case .catppuccinFrappeLight: return "Catppuccin Frappé Light"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        }
    }

    var preset: TerminalThemePreset {
        switch self {
        case .litterDark: return .litterDark
        case .catppuccinFrappe: return .catppuccinFrappe
        case .catppuccinFrappeLight: return .catppuccinFrappeLight
        case .solarizedDark: return .solarized(dark: true)
        case .solarizedLight: return .solarized(dark: false)
        }
    }

    static func preset(forId id: String) -> TerminalThemePreset {
        (TerminalThemeChoice(rawValue: id) ?? .litterDark).preset
    }
}

private struct TerminalConfigSheet: View {
    @Binding var fontSize: Double
    @Binding var themeId: String
    @Binding var cursorBlink: Bool
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Font") {
                    HStack {
                        Text("Size")
                            .font(.custom("SFMono-Regular", size: 13))
                        Spacer()
                        Text("\(Int(fontSize)) pt")
                            .font(.custom("SFMono-Regular", size: 13))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $fontSize, in: 10...18, step: 1) {
                        Text("Font size")
                    }
                    .onChange(of: fontSize) { _, _ in onApply() }
                }
                Section("Theme") {
                    Picker("Theme", selection: $themeId) {
                        ForEach(TerminalThemeChoice.allCases) { choice in
                            Text(choice.title).tag(choice.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: themeId) { _, _ in onApply() }
                }
                Section("Cursor") {
                    Toggle("Blink", isOn: $cursorBlink)
                        .onChange(of: cursorBlink) { _, _ in onApply() }
                }
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TerminalBackendOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let alleycatNodeId: String?
    let supportsResize: Bool
    let backend: TerminalBackendKind

    static func localIsh(cwd: String?) -> TerminalBackendOption {
        TerminalBackendOption(
            id: "local-ish",
            title: "Local iSH",
            subtitle: cwd?.isEmpty == false ? cwd! : "/root",
            systemImage: "iphone",
            alleycatNodeId: nil,
            supportsResize: true,
            backend: .localIsh(cwd: normalized(cwd))
        )
    }

    static func remoteAlleycat(
        name: String,
        nodeId: String,
        token: String,
        relay: String?
    ) -> TerminalBackendOption {
        TerminalBackendOption(
            id: "alleycat-\(nodeId)",
            title: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Remote shell" : name,
            subtitle: shortNodeId(nodeId),
            systemImage: "server.rack",
            alleycatNodeId: nodeId,
            supportsResize: true,
            backend: .remoteAlleycat(
                nodeId: nodeId,
                token: token,
                relay: relay,
                shell: nil
            )
        )
    }

    static func remoteSsh(
        name: String,
        host: String,
        port: UInt16,
        username: String,
        auth: TerminalSshAuth
    ) -> TerminalBackendOption {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? "\(username)@\(host)" : trimmedName
        return TerminalBackendOption(
            id: "ssh-\(host.lowercased()):\(port)",
            title: title,
            subtitle: "ssh \(username)@\(host):\(port)",
            systemImage: "terminal.fill",
            alleycatNodeId: nil,
            supportsResize: true,
            backend: .remoteSsh(
                host: host,
                port: port,
                username: username,
                auth: auth,
                shell: nil,
                acceptUnknownHost: false,
                cwd: nil
            )
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shortNodeId(_ raw: String) -> String {
        raw.count <= 16 ? raw : "\(raw.prefix(8))...\(raw.suffix(8))"
    }
}

private struct TerminalGridSize: Equatable {
    let cols: UInt16
    let rows: UInt16

    init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }

    init(size: CGSize) {
        let contentWidth = max(0, size.width - 28)
        let contentHeight = max(0, size.height - 24)
        let computedCols = Int(contentWidth / 7.8)
        let computedRows = Int(contentHeight / 17.0)
        cols = UInt16(max(20, min(240, computedCols)))
        rows = UInt16(max(4, min(120, computedRows)))
    }
}

#if DEBUG
#Preview("Terminal") {
    NavigationStack {
        TerminalScreen(cwd: "/root")
    }
}
#endif
