package dev.openchat.open_chat

import dev.openchat.open_chat.security.IdentityVault
import dev.openchat.open_chat.security.SignalBridge
import dev.openchat.open_chat.security.SignalDiagnostics
import io.flutter.embedding.android.FlutterFragmentActivity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val securityWorker = Executors.newSingleThreadExecutor()
    private var securityChannel: MethodChannel? = null
    private var privacyChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        privacyChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.openchat/privacy")
        privacyChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
                if (call.argument<Boolean>("enabled") == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(true)
            } else result.notImplemented()
        }
        securityChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.openchat/security")
        securityChannel!!.setMethodCallHandler { call, result ->
            if (call.method !in setOf("status", "initialize", "selfTest",
                     "signalPublish", "signalProcessBundle", "signalEncrypt",
                     "signalDecrypt", "blobSeal", "blobOpen", "signalHasSession",
                    "signalDeleteSession", "signalGroupCreate", "signalGroupProcess",
                    "signalGroupEncrypt", "signalGroupDecrypt", "signalGroupMarkPublished")) {
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
                        "signalGroupCreate" -> SignalBridge(applicationContext).createGroupSenderKey(
                            requiredAccount(call),
                            call.argument<String>("groupId") ?: throw IllegalArgumentException("Group required"),
                            call.argument<Number>("epoch")?.toInt() ?: throw IllegalArgumentException("Epoch required"),
                        )
                        "signalGroupMarkPublished" -> SignalBridge(applicationContext).markGroupSenderKeyPublished(
                            requiredAccount(call),
                            call.argument<String>("groupId") ?: throw IllegalArgumentException("Group required"),
                            call.argument<Number>("epoch")?.toInt() ?: throw IllegalArgumentException("Epoch required"),
                        )
                        "signalGroupProcess" -> SignalBridge(applicationContext).processGroupSenderKey(
                            requiredAccount(call),
                            call.argument<String>("groupId") ?: throw IllegalArgumentException("Group required"),
                            call.argument<Number>("epoch")?.toInt() ?: throw IllegalArgumentException("Epoch required"),
                            call.argument<String>("senderId") ?: throw IllegalArgumentException("Sender required"),
                            call.argument<String>("distribution") ?: throw IllegalArgumentException("Distribution required"),
                        )
                        "signalGroupEncrypt" -> SignalBridge(applicationContext).encryptGroup(
                            requiredAccount(call),
                            call.argument<String>("groupId") ?: throw IllegalArgumentException("Group required"),
                            call.argument<Number>("epoch")?.toInt() ?: throw IllegalArgumentException("Epoch required"),
                            call.argument<String>("plain") ?: throw IllegalArgumentException("Payload required"),
                        )
                        "signalGroupDecrypt" -> SignalBridge(applicationContext).decryptGroup(
                            requiredAccount(call),
                            call.argument<String>("groupId") ?: throw IllegalArgumentException("Group required"),
                            call.argument<Number>("epoch")?.toInt() ?: throw IllegalArgumentException("Epoch required"),
                            call.argument<String>("senderId") ?: throw IllegalArgumentException("Sender required"),
                            call.argument<String>("ciphertext") ?: throw IllegalArgumentException("Ciphertext required"),
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
                        "signalDeleteSession" -> {
                            SignalBridge(applicationContext).resetPeer(
                                requiredAccount(call),
                                call.argument<String>("peerId") ?: throw IllegalArgumentException("Contact required"),
                                call.argument<String>("identityKey"),
                            )
                            mapOf("ok" to true)
                        }
                        else -> {
                            val vault = IdentityVault(applicationContext, requiredAccount(call))
                            if (call.method == "initialize") vault.initialize() else vault.status()
                        }
                    }
                    runOnUiThread { result.success(output) }
                } catch (_: LinkageError) {
                    runOnUiThread { result.error("SIGNAL_UNAVAILABLE", "The native Signal library could not load on this device.", null) }
                } catch (error: Exception) {
                    // Forward the real failure (type + message carry operation
                    // state only; key material and serialized state never
                    // leave in exception strings).
                    val detail = "${error.javaClass.simpleName}: ${error.message ?: "failed"}"
                    runOnUiThread { result.error("SECURITY_FAILED", "Security operation failed. $detail", null) }
                }
            }
        }
    }

    private fun requiredAccount(call: MethodCall): String =
        call.argument<String>("accountId") ?: throw IllegalArgumentException("Account required")

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        privacyChannel?.setMethodCallHandler(null)
        privacyChannel = null
        securityChannel?.setMethodCallHandler(null)
        securityChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        securityWorker.shutdown()
        super.onDestroy()
    }
}
