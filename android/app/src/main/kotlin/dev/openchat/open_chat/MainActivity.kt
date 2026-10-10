package dev.openchat.open_chat

import dev.openchat.open_chat.security.IdentityVault
import dev.openchat.open_chat.security.SignalBridge
import dev.openchat.open_chat.security.SignalDiagnostics
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val securityWorker = Executors.newSingleThreadExecutor()
    private var securityChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        securityChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.openchat/security")
        securityChannel!!.setMethodCallHandler { call, result ->
            if (call.method !in setOf("status", "initialize", "selfTest",
                    "signalPublish", "signalProcessBundle", "signalEncrypt",
                    "signalDecrypt", "blobSeal", "blobOpen", "signalHasSession")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            securityWorker.execute {
                try {
                    val output: Map<String, Any> = when (call.method) {
                        "selfTest" -> SignalDiagnostics.run()
                        "signalPublish" -> SignalBridge(applicationContext).publish(requiredAccount(call))
                        "signalProcessBundle" -> {
                            val peerId = call.argument<String>("peerId") ?: throw IllegalArgumentException("Contact required")
                            @Suppress("UNCHECKED_CAST")
                            val parts = call.argument<Map<String, Any?>>("bundle") ?: throw IllegalArgumentException("Invalid bundle")
                            SignalBridge(applicationContext).processBundle(requiredAccount(call), peerId, parts)
                            mapOf("ok" to true)
                        }
                        "signalEncrypt" -> SignalBridge(applicationContext).encrypt(
                            requiredAccount(call),
                            call.argument<String>("peerId") ?: throw IllegalArgumentException("Contact required"),
                            call.argument<String>("plain") ?: throw IllegalArgumentException("Invalid payload"),
                        )
                        "signalDecrypt" -> SignalBridge(applicationContext).decrypt(
                            requiredAccount(call),
                            call.argument<String>("peerId") ?: throw IllegalArgumentException("Contact required"),
                            call.argument<Number>("type") ?: throw IllegalArgumentException("Invalid payload"),
                            call.argument<String>("body") ?: throw IllegalArgumentException("Invalid payload"),
                        )
                        "blobSeal" -> SignalBridge(applicationContext).seal(
                            requiredAccount(call),
                            call.argument<String>("data") ?: throw IllegalArgumentException("Invalid payload"),
                        )
                        "blobOpen" -> SignalBridge(applicationContext).open(
                            requiredAccount(call),
                            call.argument<String>("blob") ?: throw IllegalArgumentException("Invalid payload"),
                        )
                        "signalHasSession" -> mapOf("hasSession" to SignalBridge(applicationContext).hasSession(
                            requiredAccount(call),
                            call.argument<String>("peerId") ?: throw IllegalArgumentException("Contact required"),
                        ))
                        else -> {
                            val vault = IdentityVault(applicationContext, requiredAccount(call))
                            if (call.method == "initialize") vault.initialize() else vault.status()
                        }
                    }
                    runOnUiThread { result.success(output) }
                } catch (_: LinkageError) {
                    runOnUiThread { result.error("SIGNAL_UNAVAILABLE", "The native Signal library could not load on this device.", null) }
                } catch (_: Exception) {
                    // Do not return key material, serialized state, or internal exception strings.
                    runOnUiThread { result.error("SECURITY_FAILED", "Security operation failed. Existing keys were not replaced. Retry after unlocking your phone; if it persists, preserve app data for recovery.", null) }
                }
            }
        }
    }

    private fun requiredAccount(call: MethodCall): String =
        call.argument<String>("accountId") ?: throw IllegalArgumentException("Account required")

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        securityChannel?.setMethodCallHandler(null)
        securityChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        securityWorker.shutdown()
        super.onDestroy()
    }
}
