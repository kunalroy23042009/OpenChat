package dev.openchat.open_chat

import dev.openchat.open_chat.security.IdentityVault
import dev.openchat.open_chat.security.SignalDiagnostics
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val securityWorker = Executors.newSingleThreadExecutor()
    private var securityChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        securityChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.openchat/security")
        securityChannel!!.setMethodCallHandler { call, result ->
            if (call.method !in setOf("status", "initialize", "selfTest")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            securityWorker.execute {
                try {
                    val output = if (call.method == "selfTest") {
                        SignalDiagnostics.run()
                    } else {
                        val accountId = call.argument<String>("accountId")
                            ?: throw IllegalArgumentException("Account required")
                        val vault = IdentityVault(applicationContext, accountId)
                        if (call.method == "initialize") vault.initialize() else vault.status()
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
