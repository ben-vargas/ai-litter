package com.litter.android.ui.terminal

import android.content.Context
import android.graphics.Color
import android.os.Looper
import android.view.Choreographer
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.litter.android.core.bridge.GhosttyInputCallback
import com.litter.android.core.bridge.GhosttyRendererBridge
import com.litter.android.core.bridge.GhosttyRendererStatus
import com.litter.android.core.bridge.GhosttyWakeupListener
import com.litter.android.state.ActiveTerminalRegistry
import com.litter.android.state.TerminalSessionController
import java.io.File
import uniffi.codex_mobile_client.TerminalConfig
import uniffi.codex_mobile_client.TerminalRenderer

@Composable
internal fun GhosttyTerminalSurface(
    controller: TerminalSessionController,
    rendererStatus: GhosttyRendererStatus,
    onRendererUnavailable: () -> Unit,
    config: TerminalConfig? = null,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val viewRef = remember { GhosttySurfaceHolder() }

    AndroidView(
        factory = { context ->
            GhosttyAndroidSurfaceView(
                context = context,
                rendererStatus = rendererStatus,
                scale = density.density,
                fontSize = with(density) { 13.toSp().value },
                onRendererUnavailable = onRendererUnavailable,
                inputCallback = GhosttyInputCallback { bytes -> controller.sendBytes(bytes) },
            ).also { viewRef.view = it }
        },
        update = { view ->
            view.scale = density.density
            view.fontSize = with(density) { 13.toSp().value }
            view.inputCallback = GhosttyInputCallback { bytes -> controller.sendBytes(bytes) }
            viewRef.view = view
        },
        modifier = modifier,
    )

    DisposableEffect(controller, viewRef) {
        controller.setOutputByteSink { bytes ->
            viewRef.view?.writeTerminalBytes(bytes)
        }
        onDispose {
            controller.setOutputByteSink(null)
            viewRef.view?.inputCallback = null
            viewRef.view = null
        }
    }

    LaunchedEffect(config, viewRef) {
        config?.let { viewRef.view?.applyConfig(it) }
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, viewRef) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> viewRef.view?.setOccluded(false)
                Lifecycle.Event.ON_STOP -> viewRef.view?.setOccluded(true)
                Lifecycle.Event.ON_RESUME -> viewRef.view?.setFocused(true)
                Lifecycle.Event.ON_PAUSE -> viewRef.view?.setFocused(false)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }
}

private class GhosttySurfaceHolder {
    var view: GhosttyAndroidSurfaceView? = null
}

private class GhosttyAndroidSurfaceView(
    context: Context,
    private val rendererStatus: GhosttyRendererStatus,
    var scale: Float,
    var fontSize: Float,
    private val onRendererUnavailable: () -> Unit,
    inputCallback: GhosttyInputCallback?,
) : SurfaceView(context), SurfaceHolder.Callback {
    private val pendingBytes = ArrayDeque<ByteArray>()
    private var rendererSurface: GhosttyRendererBridge.GhosttyRendererSurface? = null
    private var terminalRenderer: TerminalRenderer? = null
    private var widthPx: Int = 1
    private var heightPx: Int = 1
    private var frameScheduled = false
    private var rendererUnavailableReported = false
    private var didSetConfigDir = false
    private var pendingConfig: TerminalConfig? = null

    var inputCallback: GhosttyInputCallback? = inputCallback
        set(value) {
            field = value
            rendererSurface?.setInputCallback(value)
        }

    private val wakeupListener = GhosttyWakeupListener {
        // Ghostty's wakeup runs on its own thread; hop to the view thread
        // and post a single Choreographer frame instead of self-rescheduling.
        post { scheduleFrame() }
    }

    private val frameCallback = Choreographer.FrameCallback {
        frameScheduled = false
        rendererSurface?.draw()
    }

    private val gestureDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onScroll(
                e1: MotionEvent?,
                e2: MotionEvent,
                distanceX: Float,
                distanceY: Float,
            ): Boolean {
                val twoFinger = e2.pointerCount >= 2
                if (!twoFinger) return false
                // `distance*` is "old - new" — invert to match natural scroll.
                rendererSurface?.mouseScroll(
                    x = -distanceX.toDouble(),
                    y = -distanceY.toDouble(),
                    precise = true,
                )
                return true
            }
        },
    )

    init {
        setBackgroundColor(Color.BLACK)
        holder.addCallback(this)
        isFocusable = true
        isFocusableInTouchMode = true
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = EditorInfo.TYPE_NULL
        outAttrs.imeOptions = (
            EditorInfo.IME_FLAG_NO_EXTRACT_UI or
                EditorInfo.IME_FLAG_NO_FULLSCREEN or
                EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING or
                EditorInfo.IME_ACTION_NONE
        )
        return GhosttyInputConnection(this)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (sendKeyEventToGhostty(event)) return true
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (sendKeyEventToGhostty(event)) return true
        return super.onKeyUp(keyCode, event)
    }

    internal fun sendKeyEventToGhostty(event: KeyEvent): Boolean {
        val renderer = rendererSurface ?: return false
        val action = when (event.action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount > 0) 2 else 1
            KeyEvent.ACTION_UP -> 0
            else -> return false
        }
        val bridgeKey = KeyEventTranslator.bridgeKey(event.keyCode)
        if (bridgeKey == 0 && event.unicodeChar == 0) {
            // Unknown key without a Unicode payload — let the system handle it
            // (back button, volume, etc).
            return false
        }
        val mods = KeyEventTranslator.packMods(event)
        val text = when {
            event.unicodeChar != 0 -> Character.toString(event.unicodeChar.toChar())
            else -> null
        }
        renderer.sendKey(action, bridgeKey, mods, text, composing = false)
        return true
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (gestureDetector.onTouchEvent(event)) return true
        val renderer = rendererSurface
        if (renderer != null && renderer.mouseCaptured()) {
            val px = event.x.toDouble()
            val py = event.y.toDouble()
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    renderer.mouseMove(px, py)
                    renderer.mouseButton(pressed = true, button = 1)
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    renderer.mouseMove(px, py)
                    return true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    renderer.mouseButton(pressed = false, button = 1)
                    return true
                }
            }
        }
        return super.onTouchEvent(event)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        createRendererSurface(holder)
    }

    override fun surfaceChanged(
        holder: SurfaceHolder,
        format: Int,
        width: Int,
        height: Int,
    ) {
        widthPx = width.coerceAtLeast(1)
        heightPx = height.coerceAtLeast(1)
        rendererSurface?.resize(widthPx, heightPx, scale) ?: createRendererSurface(holder)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopFrameLoop()
        terminalRenderer?.let { ActiveTerminalRegistry.unregister(it) }
        terminalRenderer?.detach()
        terminalRenderer?.close()
        terminalRenderer = null
        rendererSurface?.close()
        rendererSurface = null
        didSetConfigDir = false
    }

    fun writeTerminalBytes(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val ownedBytes = bytes.copyOf()
        if (Looper.myLooper() != Looper.getMainLooper()) {
            post { writeTerminalBytesOnViewThread(ownedBytes) }
            return
        }
        writeTerminalBytesOnViewThread(ownedBytes)
    }

    private fun writeTerminalBytesOnViewThread(bytes: ByteArray) {
        val activeRenderer = rendererSurface
        if (activeRenderer != null) {
            activeRenderer.write(bytes)
            return
        }

        if (pendingBytes.size >= 128) {
            pendingBytes.removeFirst()
        }
        pendingBytes.addLast(bytes)
    }

    private fun createRendererSurface(holder: SurfaceHolder) {
        if (!rendererStatus.canCreateAndroidSurface || rendererSurface != null) {
            return
        }

        val createdRenderer = GhosttyRendererBridge.createSurface(
            surface = holder.surface,
            width = widthPx,
            height = heightPx,
            scale = scale,
            fontSize = fontSize,
        )
        if (createdRenderer == null) {
            reportRendererUnavailable()
            return
        }
        rendererSurface = createdRenderer
        createdRenderer.setInputCallback(inputCallback)
        createdRenderer.setWakeupListener(wakeupListener)

        terminalRenderer = TerminalRenderer(
            backend = GhosttyRendererBackendBridge(
                surface = createdRenderer,
                onRequestRedraw = { scheduleFrame() },
            ),
        )
        terminalRenderer?.let { ActiveTerminalRegistry.register(it) }

        while (pendingBytes.isNotEmpty()) {
            rendererSurface?.write(pendingBytes.removeFirst())
        }
        pendingConfig?.let { config ->
            pendingConfig = null
            applyConfig(config)
        }
        // Paint the first frame; subsequent frames are scheduled on demand
        // via `wakeupListener` or `setOccluded(false)`.
        scheduleFrame()
    }

    fun setOccluded(occluded: Boolean) {
        terminalRenderer?.setOccluded(occluded) ?: rendererSurface?.setOcclusion(occluded)
    }

    fun setFocused(focused: Boolean) {
        terminalRenderer?.setFocused(focused) ?: rendererSurface?.setFocus(focused)
    }

    fun applyConfig(config: TerminalConfig) {
        val renderer = terminalRenderer
        if (renderer == null) {
            // Surface not created yet — replay once the renderer is attached.
            pendingConfig = config
            return
        }
        ensureConfigDir(renderer)
        try {
            renderer.applyConfig(config)
        } catch (_: Exception) {
            // Renderer was detached between the null-check and the call;
            // dropping the request is safe — the UI will retry on next change.
        }
    }

    private fun ensureConfigDir(renderer: TerminalRenderer) {
        if (didSetConfigDir) return
        val dir = File(context.cacheDir, "litter/terminal")
        renderer.setConfigDir(dir.absolutePath)
        didSetConfigDir = true
    }

    internal fun exposedRendererSurface(): GhosttyRendererBridge.GhosttyRendererSurface? =
        rendererSurface

    private fun scheduleFrame() {
        if (frameScheduled || rendererSurface == null) return
        frameScheduled = true
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    private fun stopFrameLoop() {
        if (!frameScheduled) return
        frameScheduled = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
    }

    private fun reportRendererUnavailable() {
        if (rendererUnavailableReported) return
        rendererUnavailableReported = true
        onRendererUnavailable()
    }
}

/**
 * `BaseInputConnection` shim that funnels IME commits, composing-text updates,
 * and synthesized backspaces into the Ghostty renderer. Real hardware key
 * events still flow through [GhosttyAndroidSurfaceView.onKeyDown].
 */
private class GhosttyInputConnection(
    private val view: GhosttyAndroidSurfaceView,
) : BaseInputConnection(view, /* fullEditor = */ false) {

    private fun renderer() = view.exposedRendererSurface()

    override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
        val payload = text?.toString().orEmpty()
        if (payload.isNotEmpty()) {
            renderer()?.sendText(payload)
        }
        return true
    }

    override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
        renderer()?.sendPreedit(text?.toString().takeIf { !it.isNullOrEmpty() })
        return true
    }

    override fun finishComposingText(): Boolean {
        renderer()?.sendPreedit(null)
        return true
    }

    override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
        // We don't track an editable buffer; translate to backspaces.
        val renderer = renderer() ?: return true
        repeat(beforeLength.coerceAtLeast(0)) {
            renderer.sendKey(
                action = 1,
                key = 3, // LitterBridgeKey::Backspace
                mods = 0,
                text = null,
                composing = false,
            )
        }
        return true
    }

    override fun sendKeyEvent(event: KeyEvent?): Boolean {
        val real = event ?: return false
        return view.sendKeyEventToGhostty(real)
    }
}

private object KeyEventTranslator {
    fun packMods(event: KeyEvent): Int {
        var bits = 0
        if (event.isShiftPressed) bits = bits or (1 shl 0)
        if (event.isCtrlPressed) bits = bits or (1 shl 1)
        if (event.isAltPressed) bits = bits or (1 shl 2)
        if (event.isMetaPressed) bits = bits or (1 shl 3)
        return bits
    }

    /**
     * Map Android [KeyEvent] codes to the `LitterBridgeKey` enum the JNI
     * bridge expects (1=Enter, 2=Tab, …). Returns 0 (Unidentified) for
     * codes we want to forward as Unicode text instead.
     */
    fun bridgeKey(keyCode: Int): Int = when (keyCode) {
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> 1
        KeyEvent.KEYCODE_TAB -> 2
        KeyEvent.KEYCODE_DEL -> 3
        KeyEvent.KEYCODE_ESCAPE -> 4
        KeyEvent.KEYCODE_SPACE -> 5
        KeyEvent.KEYCODE_DPAD_UP -> 6
        KeyEvent.KEYCODE_DPAD_DOWN -> 7
        KeyEvent.KEYCODE_DPAD_LEFT -> 8
        KeyEvent.KEYCODE_DPAD_RIGHT -> 9
        KeyEvent.KEYCODE_PAGE_UP -> 10
        KeyEvent.KEYCODE_PAGE_DOWN -> 11
        KeyEvent.KEYCODE_MOVE_HOME -> 12
        KeyEvent.KEYCODE_MOVE_END -> 13
        KeyEvent.KEYCODE_FORWARD_DEL -> 14
        KeyEvent.KEYCODE_INSERT -> 15
        else -> 0
    }
}
