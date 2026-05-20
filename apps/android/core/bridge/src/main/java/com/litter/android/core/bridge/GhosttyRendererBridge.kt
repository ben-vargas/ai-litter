package com.litter.android.core.bridge

import android.view.Surface

data class GhosttyRendererStatus(
    val libraryLoaded: Boolean,
    val canCreateAndroidSurface: Boolean,
    val version: String?,
    val reason: String?,
)

fun interface GhosttyInputCallback {
    fun onInput(bytes: ByteArray)
}

fun interface GhosttyWakeupListener {
    fun onWakeup()
}

object GhosttyRendererBridge {
    private const val rendererBlockedReason =
        "Ghostty Android GLES/EGL embedded surface is unavailable"

    private val loadResult: Result<Unit> by lazy {
        runCatching {
            System.loadLibrary("EGL")
            System.loadLibrary("GLESv3")
            System.loadLibrary("ghostty")
            System.loadLibrary("litter_ghostty_jni")
        }
    }

    fun status(): GhosttyRendererStatus {
        loadResult.exceptionOrNull()?.let { error ->
            return GhosttyRendererStatus(
                libraryLoaded = false,
                canCreateAndroidSurface = false,
                version = null,
                reason = error.message ?: "Unable to load Ghostty renderer library",
            )
        }

        val canCreateSurface = nativeCanCreateAndroidSurface()
        return GhosttyRendererStatus(
            libraryLoaded = true,
            canCreateAndroidSurface = canCreateSurface,
            version = nativeGhosttyVersion().takeIf { it.isNotBlank() },
            reason = if (canCreateSurface) null else rendererBlockedReason,
        )
    }

    fun createSurface(
        surface: Surface,
        width: Int,
        height: Int,
        scale: Float,
        fontSize: Float,
    ): GhosttyRendererSurface? {
        if (!status().canCreateAndroidSurface) return null
        val handle = nativeCreateAndroidSurface(
            surface,
            width.coerceAtLeast(1),
            height.coerceAtLeast(1),
            scale,
            fontSize,
        )
        return if (handle == 0L) null else GhosttyRendererSurface(handle)
    }

    private external fun nativeGhosttyVersion(): String

    private external fun nativeCanCreateAndroidSurface(): Boolean

    private external fun nativeCreateAndroidSurface(
        surface: Surface,
        width: Int,
        height: Int,
        scale: Float,
        fontSize: Float,
    ): Long

    private external fun nativeDestroyAndroidSurface(handle: Long)

    private external fun nativeResizeAndroidSurface(
        handle: Long,
        width: Int,
        height: Int,
        scale: Float,
    )

    private external fun nativeDrawAndroidSurface(handle: Long)

    private external fun nativeWriteAndroidSurface(handle: Long, data: ByteArray)

    private external fun nativeSetInputCallback(handle: Long, callback: GhosttyInputCallback?)

    private external fun nativeSetWakeupListener(handle: Long, listener: GhosttyWakeupListener?)

    private external fun nativeSetOcclusion(handle: Long, occluded: Boolean)

    private external fun nativeSetFocus(handle: Long, focused: Boolean)

    private external fun nativeApplyConfig(handle: Long, path: String): Boolean

    private external fun nativeMouseMove(handle: Long, x: Double, y: Double, mods: Int)

    private external fun nativeMouseButton(
        handle: Long,
        pressed: Boolean,
        button: Int,
        mods: Int,
    ): Boolean

    private external fun nativeMouseCaptured(handle: Long): Boolean

    private external fun nativeMouseScroll(
        handle: Long,
        x: Double,
        y: Double,
        precise: Boolean,
        mods: Int,
    )

    private external fun nativeSendKey(
        handle: Long,
        action: Int,
        key: Int,
        mods: Int,
        text: String?,
        composing: Boolean,
    ): Boolean

    private external fun nativeSendText(handle: Long, text: String)

    private external fun nativeSendPreedit(handle: Long, text: String?)

    private external fun nativeKeyboardChanged(handle: Long)

    class GhosttyRendererSurface internal constructor(
        private var handle: Long,
    ) : AutoCloseable {
        fun resize(width: Int, height: Int, scale: Float) {
            val active = handle
            if (active == 0L) return
            nativeResizeAndroidSurface(
                active,
                width.coerceAtLeast(1),
                height.coerceAtLeast(1),
                scale,
            )
        }

        fun draw() {
            val active = handle
            if (active == 0L) return
            nativeDrawAndroidSurface(active)
        }

        fun write(data: ByteArray) {
            val active = handle
            if (active == 0L || data.isEmpty()) return
            nativeWriteAndroidSurface(active, data)
        }

        fun setInputCallback(callback: GhosttyInputCallback?) {
            val active = handle
            if (active == 0L) return
            nativeSetInputCallback(active, callback)
        }

        fun setWakeupListener(listener: GhosttyWakeupListener?) {
            val active = handle
            if (active == 0L) return
            nativeSetWakeupListener(active, listener)
        }

        fun setOcclusion(occluded: Boolean) {
            val active = handle
            if (active == 0L) return
            nativeSetOcclusion(active, occluded)
        }

        fun setFocus(focused: Boolean) {
            val active = handle
            if (active == 0L) return
            nativeSetFocus(active, focused)
        }

        fun applyConfig(path: String): Boolean {
            val active = handle
            if (active == 0L) return false
            return nativeApplyConfig(active, path)
        }

        fun mouseMove(x: Double, y: Double, mods: Int = 0) {
            val active = handle
            if (active == 0L) return
            nativeMouseMove(active, x, y, mods)
        }

        fun mouseButton(pressed: Boolean, button: Int, mods: Int = 0): Boolean {
            val active = handle
            if (active == 0L) return false
            return nativeMouseButton(active, pressed, button, mods)
        }

        fun mouseCaptured(): Boolean {
            val active = handle
            if (active == 0L) return false
            return nativeMouseCaptured(active)
        }

        fun mouseScroll(x: Double, y: Double, precise: Boolean, mods: Int = 0) {
            val active = handle
            if (active == 0L) return
            nativeMouseScroll(active, x, y, precise, mods)
        }

        fun sendKey(
            action: Int,
            key: Int,
            mods: Int,
            text: String?,
            composing: Boolean,
        ): Boolean {
            val active = handle
            if (active == 0L) return false
            return nativeSendKey(active, action, key, mods, text, composing)
        }

        fun sendText(text: String) {
            val active = handle
            if (active == 0L || text.isEmpty()) return
            nativeSendText(active, text)
        }

        fun sendPreedit(text: String?) {
            val active = handle
            if (active == 0L) return
            nativeSendPreedit(active, text)
        }

        fun keyboardChanged() {
            val active = handle
            if (active == 0L) return
            nativeKeyboardChanged(active)
        }

        override fun close() {
            val active = handle
            if (active == 0L) return
            handle = 0L
            nativeSetInputCallback(active, null)
            nativeSetWakeupListener(active, null)
            nativeDestroyAndroidSurface(active)
        }
    }
}
