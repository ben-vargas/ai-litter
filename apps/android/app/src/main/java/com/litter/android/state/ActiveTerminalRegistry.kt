package com.litter.android.state

import java.lang.ref.WeakReference
import uniffi.codex_mobile_client.AppStore
import uniffi.codex_mobile_client.TerminalRenderer
import uniffi.codex_mobile_client.TerminalSendToAssistantPayload
import uniffi.codex_mobile_client.ThreadKey

/**
 * Process-wide weak hook to the most recently bound [TerminalRenderer]. The
 * terminal screen uses this for renderer-only semantic context that is not
 * part of the Rust session/store surface, such as "send selection to AI"
 * metadata.
 */
object ActiveTerminalRegistry {
    @Volatile
    private var rendererRef: WeakReference<TerminalRenderer>? = null

    fun register(renderer: TerminalRenderer) {
        rendererRef = WeakReference(renderer)
    }

    fun unregister(renderer: TerminalRenderer) {
        val current = rendererRef?.get()
        if (current === renderer) {
            rendererRef = null
        }
    }

    /**
     * Send `selection` to the assistant on `threadKey`, pulling OSC cwd +
     * last completed command from the active renderer's semantic state.
     * Suspends until [AppStore.startTurn] returns; throws on RPC error.
     */
    suspend fun sendTextToAssistant(
        store: AppStore,
        threadKey: ThreadKey,
        selection: String,
    ) {
        val renderer = rendererRef?.get() ?: return
        renderer.sendTextToAssistant(
            store = store,
            payload = TerminalSendToAssistantPayload(
                threadKey = threadKey,
                includeCwd = true,
                includeLastCommand = true,
            ),
            selection = selection,
        )
    }
}
