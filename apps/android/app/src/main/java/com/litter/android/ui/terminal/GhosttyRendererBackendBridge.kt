package com.litter.android.ui.terminal

import android.os.Handler
import android.os.Looper
import com.litter.android.core.bridge.GhosttyRendererBridge
import uniffi.codex_mobile_client.TerminalCellMetrics
import uniffi.codex_mobile_client.TerminalCellRange
import uniffi.codex_mobile_client.TerminalKeyAction
import uniffi.codex_mobile_client.TerminalKeyCode
import uniffi.codex_mobile_client.TerminalKeyEvent
import uniffi.codex_mobile_client.TerminalKeyMods
import uniffi.codex_mobile_client.TerminalRendererBackend

/**
 * Kotlin implementation of the Rust-defined `TerminalRendererBackend` callback
 * interface. The Rust [`uniffi.codex_mobile_client.TerminalRenderer`] tick task
 * invokes these methods from a tokio worker; we hop to the main thread before
 * touching the (non-thread-safe) Ghostty surface APIs.
 */
internal class GhosttyRendererBackendBridge(
    private val surface: GhosttyRendererBridge.GhosttyRendererSurface,
    private val onRequestRedraw: () -> Unit,
) : TerminalRendererBackend {

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun setFocus(focused: Boolean) {
        runOnMain { surface.setFocus(focused) }
    }

    override fun setOcclusion(occluded: Boolean) {
        runOnMain { surface.setOcclusion(occluded) }
    }

    override fun requestRedraw() {
        runOnMain { onRequestRedraw() }
    }

    override fun applyConfigFile(path: String) {
        runOnMain { surface.applyConfig(path) }
    }

    override fun dispatchKey(event: TerminalKeyEvent) {
        val action = when (event.action) {
            TerminalKeyAction.RELEASE -> 0
            TerminalKeyAction.PRESS -> 1
            TerminalKeyAction.REPEAT -> 2
        }
        val key = bridgeKey(event.code)
        val mods = packMods(event.mods)
        val text = event.text.ifEmpty { null }
        runOnMain { surface.sendKey(action, key, mods, text, composing = false) }
    }

    override fun dispatchText(text: String, composing: Boolean) {
        runOnMain {
            if (composing) {
                surface.sendPreedit(text.ifEmpty { null })
            } else if (text.isNotEmpty()) {
                surface.sendText(text)
            }
        }
    }

    override fun dispatchPaste(bytes: ByteArray) {
        // Bracketed paste bytes are valid PTY input — write them directly so
        // Ghostty's input parser sees the wrapper unmodified.
        runOnMain { surface.write(bytes) }
    }

    // Selection support — Rust drives word/line range math + read-back, but
    // the painted overlay + real ghostty_surface_read_selection wiring is
    // a follow-up PR. For now return defaults so the trait satisfies and
    // selection_set is observable when the overlay lands.
    override fun readSelection(): String? = null

    override fun readText(
        startRow: UInt,
        startCol: UInt,
        endRow: UInt,
        endCol: UInt,
    ): String? = null

    override fun cellMetrics(): TerminalCellMetrics = TerminalCellMetrics(
        cellWidthPx = 0f,
        cellHeightPx = 0f,
        cols = 0u,
        rows = 0u,
        viewportTop = 0u,
    )

    override fun setSelectionOverlay(range: TerminalCellRange?) {
        // Overlay painting arrives in the follow-up PR.
    }

    private fun packMods(mods: TerminalKeyMods): Int {
        var bits = 0
        if (mods.shift) bits = bits or (1 shl 0)
        if (mods.ctrl) bits = bits or (1 shl 1)
        if (mods.alt) bits = bits or (1 shl 2)
        if (mods.meta) bits = bits or (1 shl 3)
        return bits
    }

    // Mirrors `LitterBridgeKey` in ghostty_jni.cpp; the JNI bridge does the
    // final translation to ghostty_input_key_e.
    private fun bridgeKey(code: TerminalKeyCode): Int = when (code) {
        is TerminalKeyCode.Enter -> 1
        is TerminalKeyCode.Tab -> 2
        is TerminalKeyCode.Backspace -> 3
        is TerminalKeyCode.Escape -> 4
        is TerminalKeyCode.Space -> 5
        is TerminalKeyCode.ArrowUp -> 6
        is TerminalKeyCode.ArrowDown -> 7
        is TerminalKeyCode.ArrowLeft -> 8
        is TerminalKeyCode.ArrowRight -> 9
        is TerminalKeyCode.PageUp -> 10
        is TerminalKeyCode.PageDown -> 11
        is TerminalKeyCode.Home -> 12
        is TerminalKeyCode.End -> 13
        is TerminalKeyCode.Delete -> 14
        is TerminalKeyCode.Insert -> 15
        else -> 0
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }
}
