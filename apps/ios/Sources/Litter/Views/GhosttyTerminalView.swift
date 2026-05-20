import SwiftUI
import UIKit
import QuartzCore

@MainActor
final class GhosttyTerminalRenderer {
    var onInput: ((Data) -> Void)?
    var onNativeOutputVisibilityChanged: ((Bool) -> Void)?

    private var terminal: LitterGhosttyTerminal?
    private var renderer: TerminalRenderer?
    private var backendBridge: GhosttyRendererBackendBridge?
    private var pendingOutput: [Data] = []
    private weak var attachedView: UIView?
    private var hasNativeVisibleOutput = false
    private var didSetConfigDir = false

    func attach(to view: UIView) {
        guard terminal == nil else {
            attachedView = view
            resize(width: view.bounds.width, height: view.bounds.height, scale: view.window?.screen.scale ?? UIScreen.main.scale)
            return
        }

        attachedView = view
        do {
            let terminal = try LitterGhosttyTerminal(view: view)
            terminal.inputHandler = { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.onInput?(data)
                }
            }
            self.terminal = terminal
            let bridge = GhosttyRendererBackendBridge(terminal: terminal)
            self.backendBridge = bridge
            self.renderer = TerminalRenderer(backend: bridge)
            flushPendingOutput()
            updateNativeOutputVisibility(terminal: terminal)
        } catch {
            assertionFailure("Ghostty renderer failed: \(error.localizedDescription)")
        }
    }

    func resize(width: CGFloat, height: CGFloat, scale: CGFloat) {
        terminal?.resize(toWidth: width, height: height, scale: scale)
        renderer?.notifyNeedsDraw()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let terminal else {
            pendingOutput.append(data)
            if pendingOutput.count > 256 {
                pendingOutput.removeFirst(pendingOutput.count - 256)
            }
            return
        }
        terminal.writeOutput(data)
        renderer?.notifyNeedsDraw()
        updateNativeOutputVisibility(terminal: terminal)
    }

    func draw() {
        terminal?.draw()
    }

    func setOccluded(_ occluded: Bool) {
        renderer?.setOccluded(occluded: occluded)
    }

    func setFocused(_ focused: Bool) {
        renderer?.setFocused(focused: focused)
    }

    func sendKeyEvent(_ event: TerminalKeyEvent) {
        renderer?.sendKeyEvent(event: event)
    }

    func sendText(_ text: String, composing: Bool = false) {
        renderer?.sendText(text: text, composing: composing)
    }

    func sendPaste(_ text: String) {
        renderer?.sendPaste(text: text)
    }

    /// Send `selection` to the assistant on `threadKey`. Pulls cwd + last
    /// shell command from the renderer's OSC semantic state.
    func sendTextToAssistant(
        store: AppStore,
        threadKey: ThreadKey,
        selection: String
    ) async throws {
        guard let renderer else { return }
        try await renderer.sendTextToAssistant(
            store: store,
            payload: TerminalSendToAssistantPayload(
                threadKey: threadKey,
                includeCwd: true,
                includeLastCommand: true
            ),
            selection: selection
        )
    }

    var mouseCaptured: Bool {
        terminal?.mouseCaptured() ?? false
    }

    func sendMousePos(x: Double, y: Double, mods: Int32 = 0) {
        terminal?.mousePosX(x, y: y, mods: mods)
    }

    @discardableResult
    func sendMouseButton(pressed: Bool, button: Int32, mods: Int32 = 0) -> Bool {
        terminal?.mouseButtonPressed(pressed, button: button, mods: mods) ?? false
    }

    func sendMouseScroll(x: Double, y: Double, precise: Bool, mods: Int32 = 0) {
        terminal?.mouseScrollX(x, y: y, precise: precise, mods: mods)
    }

    func applyConfig(_ config: TerminalConfig) {
        guard let renderer else { return }
        if !didSetConfigDir {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            if let dir = cachesDir?.appendingPathComponent("litter/terminal", isDirectory: true) {
                renderer.setConfigDir(path: dir.path)
                didSetConfigDir = true
            }
        }
        do {
            try renderer.applyConfig(config: config)
        } catch {
            // Surface lifecycle race or invalid path; let user retry from sheet.
        }
    }

    func invalidate() {
        renderer?.detach()
        renderer = nil
        backendBridge = nil
        terminal?.invalidate()
        terminal = nil
        attachedView = nil
        pendingOutput.removeAll()
        didSetConfigDir = false
        setNativeOutputVisible(false)
    }

    func clearScreen() {
        guard let terminal else {
            pendingOutput.removeAll()
            setNativeOutputVisible(false)
            return
        }
        terminal.writeOutput(Data([0x1B, 0x63]))
        terminal.draw()
        setNativeOutputVisible(false)
    }

    private func flushPendingOutput() {
        guard let terminal else { return }
        for data in pendingOutput {
            terminal.writeOutput(data)
        }
        pendingOutput.removeAll()
    }

    private func updateNativeOutputVisibility(terminal: LitterGhosttyTerminal) {
        guard !hasNativeVisibleOutput else { return }
        let text = terminal.visibleText()
        if text.contains(where: { !$0.isWhitespace }) {
            setNativeOutputVisible(true)
        }
    }

    private func setNativeOutputVisible(_ value: Bool) {
        guard hasNativeVisibleOutput != value else { return }
        hasNativeVisibleOutput = value
        onNativeOutputVisibilityChanged?(value)
    }
}

struct GhosttyTerminalView: UIViewRepresentable {
    let renderer: GhosttyTerminalRenderer
    let onNativeOutputVisibilityChanged: (Bool) -> Void
    let onInput: (Data) -> Void

    func makeUIView(context: Context) -> GhosttyHostView {
        let view = GhosttyHostView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.renderer = renderer
        renderer.onInput = onInput
        renderer.onNativeOutputVisibilityChanged = onNativeOutputVisibilityChanged
        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: GhosttyHostView, context: Context) {
        renderer.onInput = onInput
        renderer.onNativeOutputVisibilityChanged = onNativeOutputVisibilityChanged
        uiView.renderer = renderer
        renderer.resize(
            width: uiView.bounds.width,
            height: uiView.bounds.height,
            scale: uiView.window?.screen.scale ?? UIScreen.main.scale
        )
    }

    static func dismantleUIView(_ uiView: GhosttyHostView, coordinator: ()) {
        uiView.teardownForDismissal()
        uiView.renderer?.invalidate()
        uiView.renderer = nil
    }
}

/// Invisible UITextField overlaid on the Ghostty surface. UIKit hands us
/// hardware key presses (via `pressesBegan`) and IME-decoded text (via
/// `insertText`); we translate to Rust `TerminalKeyEvent`s + text and let
/// the renderer forward to Ghostty's CSI/kitty encoder.
final class LitterGhosttyInputView: UITextField {
    weak var renderer: GhosttyTerminalRenderer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        keyboardAppearance = .dark
        keyboardType = .asciiCapable
        returnKeyType = .default
        textColor = .clear
        tintColor = .clear
        isOpaque = false
        backgroundColor = .clear
        accessibilityLabel = "Terminal input"
    }

    override func insertText(_ text: String) {
        renderer?.sendText(text)
    }

    override func deleteBackward() {
        renderer?.sendKeyEvent(
            TerminalKeyEvent(
                action: .press,
                code: .backspace,
                mods: TerminalKeyMods(shift: false, ctrl: false, alt: false, meta: false),
                text: "",
                repeat: false
            )
        )
    }

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if let event = Self.terminalEvent(for: key, action: .press, repeated: false) {
                renderer?.sendKeyEvent(event)
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    private static func terminalEvent(
        for key: UIKey,
        action: TerminalKeyAction,
        repeated: Bool
    ) -> TerminalKeyEvent? {
        let code = mapHIDUsage(key.keyCode)
        // Only forward keys we have a code for; printable characters arrive
        // separately via `insertText` so the IME decision (e.g. dead keys)
        // stays in UIKit.
        if code == .unidentified { return nil }
        let mods = TerminalKeyMods(
            shift: key.modifierFlags.contains(.shift),
            ctrl: key.modifierFlags.contains(.control),
            alt: key.modifierFlags.contains(.alternate),
            meta: key.modifierFlags.contains(.command)
        )
        return TerminalKeyEvent(
            action: action,
            code: code,
            mods: mods,
            text: key.characters,
            repeat: repeated
        )
    }

    private static func mapHIDUsage(_ keyCode: UIKeyboardHIDUsage) -> TerminalKeyCode {
        switch keyCode {
        case .keyboardReturnOrEnter: return .enter
        case .keyboardTab: return .tab
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardEscape: return .escape
        case .keyboardSpacebar: return .space
        case .keyboardUpArrow: return .arrowUp
        case .keyboardDownArrow: return .arrowDown
        case .keyboardLeftArrow: return .arrowLeft
        case .keyboardRightArrow: return .arrowRight
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardDeleteForward: return .delete
        case .keyboardInsert: return .insert
        case .keyboardF1: return .f1
        case .keyboardF2: return .f2
        case .keyboardF3: return .f3
        case .keyboardF4: return .f4
        case .keyboardF5: return .f5
        case .keyboardF6: return .f6
        case .keyboardF7: return .f7
        case .keyboardF8: return .f8
        case .keyboardF9: return .f9
        case .keyboardF10: return .f10
        case .keyboardF11: return .f11
        case .keyboardF12: return .f12
        default: return .unidentified
        }
    }
}

final class GhosttyHostView: UIView {
    weak var renderer: GhosttyTerminalRenderer? {
        didSet { keyboardOverlay.renderer = renderer }
    }
    private var scrollPan: UIPanGestureRecognizer?
    private var dragPan: UIPanGestureRecognizer?
    private var lastScrollTranslation: CGPoint = .zero
    private var dragInProgress = false
    private let keyboardOverlay = LitterGhosttyInputView()

    override class var layerClass: AnyClass { CAMetalLayer.self }

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addInputView()
        installGestureRecognizers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addInputView()
        installGestureRecognizers()
    }

    private func addInputView() {
        keyboardOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardOverlay)
        NSLayoutConstraint.activate([
            keyboardOverlay.topAnchor.constraint(equalTo: topAnchor),
            keyboardOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboardOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        keyboardOverlay.alpha = 0
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        keyboardOverlay.becomeFirstResponder()
        return result
    }

    private func installGestureRecognizers() {
        // Single-finger pan scrolls the scrollback (mobile-native). When a
        // mouse-tracking app (vim/htop) has captured the mouse, the drag
        // pan takes over for mouse drag instead.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scroll.minimumNumberOfTouches = 1
        scroll.maximumNumberOfTouches = 2
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        addGestureRecognizer(scroll)
        scrollPan = scroll

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDragPan(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        drag.cancelsTouchesInView = false
        drag.delegate = self
        addGestureRecognizer(drag)
        dragPan = drag

        // Tap-to-focus: bring up the keyboard when the user taps the
        // surface. Without this the hidden UITextField overlay sits idle
        // and the user can't type.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        _ = keyboardOverlay.becomeFirstResponder()
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let renderer else { return }
        // Don't double-handle: when a mouse-tracking app has captured the
        // mouse, dragPan owns single-finger touches.
        if renderer.mouseCaptured && gesture.numberOfTouches == 1 { return }
        switch gesture.state {
        case .began:
            lastScrollTranslation = .zero
        case .changed:
            let translation = gesture.translation(in: self)
            let dx = Double(translation.x - lastScrollTranslation.x)
            let dy = Double(translation.y - lastScrollTranslation.y)
            lastScrollTranslation = translation
            renderer.sendMouseScroll(x: dx, y: dy, precise: true)
        case .ended, .cancelled, .failed:
            lastScrollTranslation = .zero
        default:
            break
        }
    }

    @objc private func handleDragPan(_ gesture: UIPanGestureRecognizer) {
        guard let renderer, renderer.mouseCaptured else {
            if dragInProgress {
                renderer?.sendMouseButton(pressed: false, button: 1)
                dragInProgress = false
            }
            return
        }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let location = gesture.location(in: self)
        let px = Double(location.x * scale)
        let py = Double(location.y * scale)
        switch gesture.state {
        case .began:
            renderer.sendMousePos(x: px, y: py)
            renderer.sendMouseButton(pressed: true, button: 1)
            dragInProgress = true
        case .changed:
            renderer.sendMousePos(x: px, y: py)
        case .ended, .cancelled, .failed:
            renderer.sendMouseButton(pressed: false, button: 1)
            dragInProgress = false
        default:
            break
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
            renderer?.attach(to: self)
        } else {
            teardownForDismissal()
        }
    }

    /// Release the hidden UITextField's first-responder hold and ask the
    /// renderer to idle. Without this, leaving the terminal leaves the
    /// keyboard up and the parent screen receives no taps because the
    /// first-responder chain is still pinned to a now-offscreen overlay.
    func teardownForDismissal() {
        keyboardOverlay.resignFirstResponder()
        _ = resignFirstResponder()
        renderer?.setFocused(false)
        renderer?.setOccluded(true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderer?.resize(
            width: bounds.width,
            height: bounds.height,
            scale: window?.screen.scale ?? UIScreen.main.scale
        )
    }
}

extension GhosttyHostView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Allow the host view's gestures to run alongside the hidden
        // UITextField's own touch handling so a tap can both focus the
        // keyboard and pass through to a pan.
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Never swallow touches destined for UI controls inside the
        // overlay (selection handles, future buttons).
        if touch.view is UIControl { return false }
        return true
    }
}
