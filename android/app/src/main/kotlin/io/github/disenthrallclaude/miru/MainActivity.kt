package io.github.disenthrallclaude.miru

import android.app.PendingIntent
import android.content.Intent
import android.content.IntentFilter
import android.content.BroadcastReceiver
import android.content.pm.PackageManager
import android.app.RemoteAction
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import android.net.Uri
import android.app.PictureInPictureParams
import android.graphics.drawable.Icon
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Rational
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity: AudioServiceActivity() {
    private val CHANNEL = "io.github.disenthrallclaude.miru/intent"
    private val STORAGE_CHANNEL = "io.github.disenthrallclaude.miru/storage"
    private val PIP_CHANNEL = "io.github.disenthrallclaude.miru/pip"
    private val CRYPTO_CHANNEL = "io.github.disenthrallclaude.miru/crypto"
    private var intentChannel: MethodChannel? = null
    private var pipChannel: MethodChannel? = null

    // Android Keystore 别名：硬件级密钥用于加密敏感设置项（如 WebDAV 密码），
    // 密钥不可导出，卸载应用后自动销毁。
    private val keystoreAlias = "miru_secure_field_key"
    private val cipherPrefix = "v1:"

    private var pipIsPlaying = false
    private var pipDanmakuEnabled = false
    private var pipActionReceiverRegistered = false
    private var autoEnterPipOnHomeGesture = false
    private var pipInPlayerPage = false
    private var pipAspectWidth = 16
    private var pipAspectHeight = 9
    private var androidFullscreen = false

    private val actionPipPlayPause = "io.github.disenthrallclaude.miru.pip.PLAY_PAUSE"
    private val actionPipForward = "io.github.disenthrallclaude.miru.pip.FORWARD"
    private val actionPipToggleDanmaku = "io.github.disenthrallclaude.miru.pip.TOGGLE_DANMAKU"

    private val pipActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            val action = intent?.action ?: return
            when (action) {
                actionPipPlayPause -> notifyFlutterPipAction("play_pause")
                actionPipForward -> notifyFlutterPipAction("forward")
                actionPipToggleDanmaku -> notifyFlutterPipAction("toggle_danmaku")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerPipActionReceiverIfNeeded()
    }

    override fun onDestroy() {
        unregisterPipActionReceiverIfNeeded()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && androidFullscreen) {
            applyAndroidFullscreen()
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        intentChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        intentChannel?.setMethodCallHandler { call, result ->
            if (call.method == "openWithMime") {
                val url = call.argument<String>("url")
                val mimeType = call.argument<String>("mimeType")
                if (url != null && mimeType != null) {
                    openWithMime(url, mimeType)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "URL and MIME type required", null)
                }
            } else if (call.method == "checkIfInMultiWindowMode") {
                val isInMultiWindow = checkIfInMultiWindowMode()
                result.success(isInMultiWindow)
            } else if (call.method == "getAndroidSdkVersion") {
                val sdkVersion = getAndroidSdkVersion()
                result.success(sdkVersion)
            } else if (call.method == "enterFullscreen") {
                enterAndroidFullscreen()
                result.success(null)
            } else if (call.method == "exitFullscreen") {
                exitAndroidFullscreen()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getAvailableStorage") {
                val path = call.argument<String>("path") ?: filesDir.absolutePath
                val availableBytes = getAvailableStorage(path)
                result.success(availableBytes)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CRYPTO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "encrypt" -> {
                    val value = call.argument<String>("value")
                    if (value == null) {
                        result.error("INVALID_ARGUMENT", "value required", null)
                    } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                        result.error("UNSUPPORTED", "Android Keystore requires API 23+", null)
                    } else {
                        try {
                            result.success(encryptWithKeystore(value))
                        } catch (e: Exception) {
                            result.error("CRYPTO_ERROR", e.message, null)
                        }
                    }
                }
                "decrypt" -> {
                    val value = call.argument<String>("value")
                    if (value == null) {
                        result.error("INVALID_ARGUMENT", "value required", null)
                    } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                        result.error("UNSUPPORTED", "Android Keystore requires API 23+", null)
                    } else {
                        try {
                            result.success(decryptWithKeystore(value))
                        } catch (e: Exception) {
                            result.error("CRYPTO_ERROR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
        pipChannel?.setMethodCallHandler { call, result ->
            if (call.method == "isPictureInPictureSupported") {
                result.success(isPictureInPictureSupported())
            } else if (call.method == "enterPictureInPictureMode") {
                pipAspectWidth = call.argument<Int>("width") ?: pipAspectWidth
                pipAspectHeight = call.argument<Int>("height") ?: pipAspectHeight
                val entered = enterPictureInPicture()
                result.success(entered)
            } else if (call.method == "updatePictureInPictureActions") {
                val playing = call.argument<Boolean>("playing") ?: false
                val danmakuEnabled = call.argument<Boolean>("danmakuEnabled") ?: false
                pipAspectWidth = call.argument<Int>("width") ?: pipAspectWidth
                pipAspectHeight = call.argument<Int>("height") ?: pipAspectHeight
                updatePictureInPictureActions(playing, danmakuEnabled)
                result.success(true)
            } else if (call.method == "setAndroidAutoEnterPIPEnabled") {
                autoEnterPipOnHomeGesture = call.argument<Boolean>("enabled") ?: false
                refreshPictureInPictureParamsIfNeeded()
                result.success(true)
            } else if (call.method == "setAndroidPIPInPlayerPage") {
                pipInPlayerPage = call.argument<Boolean>("inPlayerPage") ?: false
                refreshPictureInPictureParamsIfNeeded()
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun openWithMime(url: String, mimeType: String) {
        val intent = Intent()
        intent.action = Intent.ACTION_VIEW
        intent.setDataAndType(Uri.parse(url), mimeType)
        startActivity(intent)
    }

    private fun checkIfInMultiWindowMode(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            this.isInMultiWindowMode 
        } else {
            false 
        }
    }

    private fun getAndroidSdkVersion(): Int {
        return Build.VERSION.SDK_INT
    }

    private fun enterAndroidFullscreen() {
        androidFullscreen = true
        applyAndroidFullscreen()
    }

    private fun applyAndroidFullscreen() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    private fun exitAndroidFullscreen() {
        androidFullscreen = false
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView)
            .show(WindowInsetsCompat.Type.systemBars())
    }

    private fun isPictureInPictureSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        return packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun enterPictureInPicture(): Boolean {
        if (!isPictureInPictureSupported()) {
            return false
        }
        if (isInPictureInPictureMode) {
            return true
        }
        return enterPictureInPictureMode(buildPictureInPictureParams())
    }

    private fun updatePictureInPictureActions(
        playing: Boolean,
        danmakuEnabled: Boolean
    ) {
        if (!isPictureInPictureSupported()) {
            return
        }
        pipIsPlaying = playing
        pipDanmakuEnabled = danmakuEnabled
        refreshPictureInPictureParamsIfNeeded()
    }

    private fun buildPictureInPictureParams(): PictureInPictureParams {
        val actions = buildPipActions()
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(pipAspectWidth, pipAspectHeight))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnterPipOnHomeGesture && pipInPlayerPage)
            builder.setSeamlessResizeEnabled(false)
        }
        if (actions.isNotEmpty()) {
            builder.setActions(actions)
        }
        return builder.build()
    }

    private fun refreshPictureInPictureParamsIfNeeded() {
        if (!isPictureInPictureSupported()) {
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setPictureInPictureParams(buildPictureInPictureParams())
        }
    }

    private fun buildPipActions(): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return emptyList()
        }

        val allActions = mutableListOf<RemoteAction>(
            createPipAction(
                action = actionPipToggleDanmaku,
                requestCode = 1003,
                iconRes = if (pipDanmakuEnabled) R.drawable.ic_pip_danmaku_on else R.drawable.ic_pip_danmaku_off,
                title = if (pipDanmakuEnabled) "Danmaku On" else "Danmaku Off",
                description = if (pipDanmakuEnabled) "Turn off danmaku" else "Turn on danmaku",
                enabled = true
            ),
            createPipAction(
                action = actionPipPlayPause,
                requestCode = 1001,
                iconRes = if (pipIsPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                title = if (pipIsPlaying) "Pause" else "Play",
                description = if (pipIsPlaying) "Pause playback" else "Play playback",
                enabled = true
            ),
            createPipAction(
                action = actionPipForward,
                requestCode = 1002,
                iconRes = R.drawable.ic_pip_forward_80,
                title = "Forward",
                description = "Forward by custom seconds",
                enabled = true
            )
        )

        val maxActions = maxNumPictureInPictureActions
        if (allActions.size > maxActions) {
            allActions.subList(maxActions, allActions.size).clear()
        }
        return allActions
    }

    private fun createPipAction(
        action: String,
        requestCode: Int,
        iconRes: Int,
        title: String,
        description: String,
        enabled: Boolean
    ): RemoteAction {
        val intent = Intent(action).setPackage(packageName)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return RemoteAction(
            Icon.createWithResource(this, iconRes),
            title,
            description,
            pendingIntent
        ).apply {
            setEnabled(enabled)
        }
    }

    private fun notifyFlutterPipAction(action: String) {
        pipChannel?.invokeMethod("onAction", mapOf("action" to action))
    }

    private fun registerPipActionReceiverIfNeeded() {
        if (pipActionReceiverRegistered || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val filter = IntentFilter().apply {
            addAction(actionPipPlayPause)
            addAction(actionPipForward)
            addAction(actionPipToggleDanmaku)
        }
        ContextCompat.registerReceiver(
            this,
            pipActionReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        pipActionReceiverRegistered = true
    }

    private fun unregisterPipActionReceiverIfNeeded() {
        if (!pipActionReceiverRegistered) {
            return
        }
        unregisterReceiver(pipActionReceiver)
        pipActionReceiverRegistered = false
    }

    private fun getAvailableStorage(path: String): Long {
        return try {
            val stat = StatFs(path)
            stat.availableBlocksLong * stat.blockSizeLong
        } catch (e: Exception) {
            -1L
        }
    }

    private fun getOrCreateKeystoreKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(keystoreAlias, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                keystoreAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    // 输出格式: v1:base64(iv):base64(ciphertext)。AES-GCM 每次加密使用随机 IV。
    private fun encryptWithKeystore(plainText: String): String {
        if (plainText.isEmpty()) {
            return plainText
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKeystoreKey())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        val ivB64 = Base64.encodeToString(iv, Base64.NO_WRAP)
        val dataB64 = Base64.encodeToString(encrypted, Base64.NO_WRAP)
        return "$cipherPrefix$ivB64:$dataB64"
    }

    // 非 v1: 前缀的历史明文直接透传，由 Dart 侧决定是否回写升级为密文。
    private fun decryptWithKeystore(storedValue: String): String? {
        if (!storedValue.startsWith(cipherPrefix)) {
            return storedValue
        }
        val parts = storedValue.split(":")
        if (parts.size != 3) {
            throw IllegalArgumentException("Malformed cipher payload")
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateKeystoreKey(),
            GCMParameterSpec(128, Base64.decode(parts[1], Base64.NO_WRAP))
        )
        val plain = cipher.doFinal(Base64.decode(parts[2], Base64.NO_WRAP))
        return String(plain, Charsets.UTF_8)
    }
}
