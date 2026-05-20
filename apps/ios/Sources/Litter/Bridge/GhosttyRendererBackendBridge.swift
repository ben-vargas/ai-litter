import Foundation

/// Thin Swift implementation of the Rust-defined `TerminalRendererBackend`
/// callback interface. Holds a weak reference to the platform-side
/// `LitterGhosttyTerminal` and hops every Ghostty C call onto the main
/// thread (Ghostty's surface APIs are not thread-safe). The Rust tick task
/// invokes these methods on the shared tokio runtime.
final class GhosttyRendererBackendBridge: TerminalRendererBackend, @unchecked Sendable {
    private weak var terminal: LitterGhosttyTerminal?

    init(terminal: LitterGhosttyTerminal) {
        self.terminal = terminal
    }

    func setFocus(focused: Bool) {
        let terminal = self.terminal
        DispatchQueue.main.async {
            terminal?.setFocused(focused)
        }
    }

    func setOcclusion(occluded: Bool) {
        let terminal = self.terminal
        DispatchQueue.main.async {
            terminal?.setOcclusion(occluded)
        }
    }

    func requestRedraw() {
        // `LitterGhosttyTerminal.requestRedraw` already hops to main.
        terminal?.requestRedraw()
    }

    func applyConfigFile(path: String) {
        let terminal = self.terminal
        DispatchQueue.main.async {
            try? terminal?.applyConfig(atPath: path)
        }
    }

    func dispatchKey(event: TerminalKeyEvent) {
        let terminal = self.terminal
        let action = Int32(GhosttyKeyTranslator.action(for: event.action))
        let litterKey = GhosttyKeyTranslator.litterKey(for: event.code)
        let mods = Int32(GhosttyKeyTranslator.mods(for: event.mods))
        let text = event.text.isEmpty ? nil : event.text
        DispatchQueue.main.async {
            _ = terminal?.dispatchKeyAction(
                action,
                key: litterKey,
                mods: mods,
                text: text,
                composing: false
            )
        }
    }

    func dispatchText(text: String, composing: Bool) {
        let terminal = self.terminal
        DispatchQueue.main.async {
            if composing {
                terminal?.setPreeditText(text.isEmpty ? nil : text)
            } else {
                terminal?.sendText(text)
            }
        }
    }

    func dispatchPaste(bytes: Data) {
        let terminal = self.terminal
        DispatchQueue.main.async {
            terminal?.writeOutput(bytes)
        }
    }

    // Selection support — the iOS-side painted overlay + range plumbing
    // lands in a follow-up. For now we expose the read paths and return a
    // best-effort metrics estimate so word/line range math has something
    // to work with; platform UI can wire in a real overlay later.
    func readSelection() -> String? {
        // `LitterGhosttyTerminal.visibleText` doesn't differentiate the
        // active selection from the viewport. Return `nil` until the
        // overlay PR wires `ghostty_surface_read_selection`.
        nil
    }

    func readText(startRow: UInt32, startCol: UInt32, endRow: UInt32, endCol: UInt32) -> String? {
        nil
    }

    func cellMetrics() -> TerminalCellMetrics {
        TerminalCellMetrics(
            cellWidthPx: 0,
            cellHeightPx: 0,
            cols: 0,
            rows: 0,
            viewportTop: 0
        )
    }

    func setSelectionOverlay(range: TerminalCellRange?) {
        // Painted overlay arrives in a follow-up; storing the range here
        // would just be dead state. No-op until that lands.
    }
}

/// Translation: Rust `TerminalKey*` → bridge-level `LitterGhosttyKey`.
/// Bridge does the final Ghostty-enum mapping in Obj-C.
enum GhosttyKeyTranslator {
    static func action(for value: TerminalKeyAction) -> Int {
        switch value {
        case .release: return 0
        case .press: return 1
        case .repeat: return 2
        }
    }

    static func mods(for value: TerminalKeyMods) -> Int {
        var bits = 0
        if value.shift { bits |= 1 << 0 }
        if value.ctrl { bits |= 1 << 1 }
        if value.alt { bits |= 1 << 2 }
        if value.meta { bits |= 1 << 3 }
        return bits
    }

    static func litterKey(for value: TerminalKeyCode) -> LitterGhosttyKey {
        switch value {
        case .enter: return .enter
        case .tab: return .tab
        case .backspace: return .backspace
        case .escape: return .escape
        case .space: return .space
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .home: return .home
        case .end: return .end
        case .delete: return .delete
        case .insert: return .insert
        default: return .unidentified
        }
    }
}
