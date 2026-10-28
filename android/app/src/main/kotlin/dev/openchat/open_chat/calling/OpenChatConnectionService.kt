package dev.openchat.open_chat.calling

import android.content.Context
import android.content.ComponentName
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ConcurrentHashMap

class OpenChatConnectionService : ConnectionService() {

    companion object {
        const val TAG = "OpenChatConnectionService"
        const val CHANNEL = "dev.openchat/calling_service"
        const val ACCOUNT_HANDLE = "openchat_account"
        private var appContext: Context? = null
        private var methodChannel: MethodChannel? = null
        private const val EXTRA_UUID = "dev.openchat.call.uuid"
        private const val EXTRA_NAME = "dev.openchat.call.name"

        fun setFlutterEngine(engine: FlutterEngine, context: Context) {
            appContext = context.applicationContext
            methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            methodChannel?.setMethodCallHandler { call, result ->
                handleMethodCall(call, result)
            }
        }

        private fun handleMethodCall(call: MethodCall, result: Result) {
            when (call.method) {
                "reportIncomingCall" -> {
                    val uuid = call.argument<String>("uuid") ?: return result.success(false)
                    val handle = call.argument<String>("handle") ?: return result.success(false)
                    val video = call.argument<Boolean>("video") ?: false
                    val name = call.argument<String>("name") ?: "Unknown"
                    val context = appContext ?: return result.success(false)
                    try {
                        val account = PhoneAccountHandle(
                            ComponentName(context, OpenChatConnectionService::class.java),
                            ACCOUNT_HANDLE
                        )
                        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                        telecom.registerPhoneAccount(
                            PhoneAccount.builder(account, "OpenChat")
                                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                                .build()
                        )
                        telecom.addNewIncomingCall(account, Bundle().apply {
                            putString(EXTRA_UUID, uuid)
                            putString(EXTRA_NAME, name)
                            putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.fromParts("sip", handle, null))
                            putInt(TelecomManager.EXTRA_INCOMING_VIDEO_STATE,
                                if (video) VideoProfile.STATE_BIDIRECTIONAL else VideoProfile.STATE_AUDIO_ONLY)
                        })
                        result.success(true)
                    } catch (error: RuntimeException) {
                        result.error("telecom_unavailable", error.message, null)
                    }
                }
                "reportCallConnected" -> {
                    val uuid = call.argument<String>("uuid") ?: return result.success(false)
                    val connection = activeConnections[uuid]
                    connection?.reportConnected()
                    result.success(connection != null)
                }
                "reportCallEnded" -> {
                    val uuid = call.argument<String>("uuid") ?: return result.success(false)
                    val connection = activeConnections[uuid]
                    connection?.reportDisconnected()
                    result.success(connection != null)
                }
                else -> result.notImplemented()
            }
        }

        private val activeConnections = ConcurrentHashMap<String, OpenChatConnection>()
    }

    private lateinit var accountHandle: PhoneAccountHandle

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "ConnectionService created")

        accountHandle = PhoneAccountHandle(
            ComponentName(this, OpenChatConnectionService::class.java),
            ACCOUNT_HANDLE
        )

        val telecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        telecomManager.registerPhoneAccount(
            android.telecom.PhoneAccount.Builder(accountHandle, "OpenChat")
                .setCapabilities(
                    android.telecom.PhoneAccount.CAPABILITY_SELF_MANAGED
                )
                .build()
        )
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val uuid = request.extras?.getString(EXTRA_UUID) ?: java.util.UUID.randomUUID().toString()
        val handle = request.address?.schemeSpecificPart ?: "Unknown"
        val video = VideoProfile.isVideo(request.videoState)
        val name = request.extras?.getString(EXTRA_NAME) ?: handle

        Log.d(TAG, "Incoming connection: $uuid, handle: $handle, video: $video")

        val connection = OpenChatConnection(this, uuid, handle, video, true)
        connection.setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
        connection.setRinging()
        activeConnections[uuid] = connection

        // Notify Flutter of incoming call
        methodChannel?.invokeMethod("onIncomingCall", mapOf(
            "uuid" to uuid,
            "handle" to handle,
            "video" to video,
            "name" to name
        ))

        return connection
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val uuid = request.extras?.getString(EXTRA_UUID) ?: java.util.UUID.randomUUID().toString()
        val handle = request.address?.schemeSpecificPart ?: "Unknown"
        val video = VideoProfile.isVideo(request.videoState)

        Log.d(TAG, "Outgoing connection: $uuid, handle: $handle, video: $video")

        val connection = OpenChatConnection(this, uuid, handle, video, false)
        connection.setDialing()
        activeConnections[uuid] = connection

        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ) {
        val uuid = request.extras?.getString(EXTRA_UUID) ?: return
        activeConnections.remove(uuid)?.reportDisconnected()
        methodChannel?.invokeMethod("onCallEnded", mapOf("uuid" to uuid))
    }

    inner class OpenChatConnection(
        private val service: OpenChatConnectionService,
        val uuid: String,
        val handle: String,
        val video: Boolean,
        val isIncoming: Boolean
    ) : Connection() {

        init {
            setAddress(Uri.fromParts("sip", handle, null), TelecomManager.PRESENTATION_ALLOWED)
            setVideoState(if (video) VideoProfile.STATE_BIDIRECTIONAL else VideoProfile.STATE_AUDIO_ONLY)
            setConnectionProperties(Connection.PROPERTY_SELF_MANAGED)
            setAudioModeIsVoip(true)
            setCallerDisplayName(handle, TelecomManager.PRESENTATION_ALLOWED)
        }

        override fun onAnswer() {
            Log.d(TAG, "Answer: $uuid")
            setActive()
            activeConnections[uuid] = this
            methodChannel?.invokeMethod("onCallAnswered", mapOf("uuid" to uuid))
        }

        override fun onReject() {
            Log.d(TAG, "Reject: $uuid")
            setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
            destroy()
            activeConnections.remove(uuid)
            methodChannel?.invokeMethod("onCallDeclined", mapOf("uuid" to uuid))
        }

        override fun onDisconnect() {
            Log.d(TAG, "Disconnect: $uuid")
            setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
            destroy()
            activeConnections.remove(uuid)
            methodChannel?.invokeMethod("onCallEnded", mapOf("uuid" to uuid))
        }

        override fun onHold() {
            Log.d(TAG, "Hold: $uuid")
            setOnHold()
        }

        override fun onUnhold() {
            Log.d(TAG, "Unhold: $uuid")
            setActive()
        }

        override fun onStateChanged(state: Int) {
            Log.d(TAG, "State changed: $uuid -> $state")
        }

        override fun onPostDialContinue(proceed: Boolean) {
            // Not used
        }

        fun reportConnected() {
            setActive()
        }

        fun reportDisconnected() {
            setDisconnected(DisconnectCause(DisconnectCause.REMOTE))
            destroy()
            activeConnections.remove(uuid)
        }
    }

}
