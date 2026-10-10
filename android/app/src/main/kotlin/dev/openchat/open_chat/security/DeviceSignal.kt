package dev.openchat.open_chat.security

import android.content.Context
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.util.UUID
import org.signal.libsignal.protocol.SignalProtocolAddress

/** Android binding: Keystore-backed encrypted store file plus base64 codec.
 *  All protocol logic lives in the JVM-tested SignalSessions. */
class DeviceSignalStore(context: Context, accountId: String) {
    private val account = UUID.fromString(accountId).toString()
    private val vault = IdentityVault(context, account)
    private val file = File(context.noBackupFilesDir, "signal-store-$account.bin")
    private val atomicFile = AtomicFile(file)
    private val sessionsAad = "openchat.sessions.v1:$account".toByteArray(Charsets.UTF_8)
    private val blobAad = "openchat.blob.v1:$account".toByteArray(Charsets.UTF_8)

    private val backend = object : SignalStoreBackend {
        override fun load(): ByteArray? {
            if (!file.exists()) return null
            return CryptoEnvelope.open(vault.wrappingKey(), sessionsAad, 2, atomicFile.readFully(), 1_000_000)
        }
        override fun store(data: ByteArray) {
            val sealed = CryptoEnvelope.seal(vault.wrappingKey(), sessionsAad, 2, data)
            val output = atomicFile.startWrite()
            try {
                output.write(sealed)
                atomicFile.finishWrite(output)
            } catch (error: Exception) {
                atomicFile.failWrite(output)
                throw error
            }
        }
    }

    fun open(): PersistentSignalStore {
        vault.initialize()
        val (identity, registrationId) = vault.identityPair()
        return PersistentSignalStore(backend, identity, registrationId)
    }

    fun sealBlob(data: ByteArray): ByteArray {
        require(data.size in 1..4_000_000) { "Blob size out of bounds" }
        vault.initialize()
        return CryptoEnvelope.seal(vault.wrappingKey(), blobAad, 3, data)
    }

    fun openBlob(blob: ByteArray): ByteArray {
        vault.initialize()
        return CryptoEnvelope.open(vault.wrappingKey(), blobAad, 3, blob, 5_000_000)
    }
}

class SignalBridge(private val context: Context) {
    private fun b64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun unb64(value: Any?): ByteArray {
        require(value is String && value.length in 4..20000) { "Invalid payload" }
        return try { Base64.decode(value, Base64.NO_WRAP) } catch (_: IllegalArgumentException) {
            throw IllegalArgumentException("Invalid payload")
        }
    }
    private fun address(id: Any?): SignalProtocolAddress {
        require(id is String) { "Account required" }
        return SignalProtocolAddress(UUID.fromString(id).toString(), 1)
    }
    private fun store(accountId: String) = DeviceSignalStore(context, accountId).open()

    fun publish(accountId: String): Map<String, Any> {
        val bundle = SignalSessions.freshBundle(store(accountId), 20, 5)
        return mapOf(
            "identityKey" to b64(bundle.identityKey),
            "registrationId" to bundle.registrationId,
            "signedPrekeyId" to bundle.signedPrekeyId,
            "signedPrekey" to b64(bundle.signedPrekey),
            "signedPrekeySignature" to b64(bundle.signedPrekeySignature),
            "prekeys" to bundle.prekeys.map { mapOf("id" to it.first, "key" to b64(it.second)) },
            "kyber" to bundle.kyber.map { mapOf("id" to it.first, "key" to b64(it.second), "signature" to b64(it.third)) },
        )
    }

    fun processBundle(accountId: String, peerId: String, parts: Map<String, Any?>) {
        fun optInt(key: String): Int? = (parts[key] as? Number)?.toInt()
        fun optBytes(key: String): ByteArray? = (parts[key] as? String)?.let { unb64(it) }
        val bundle = BundleParts(
            registrationId = (parts["registrationId"] as? Number)?.toInt() ?: throw IllegalArgumentException("Invalid bundle"),
            identityKey = unb64(parts["identityKey"]),
            signedPrekeyId = (parts["signedPrekeyId"] as? Number)?.toInt() ?: throw IllegalArgumentException("Invalid bundle"),
            signedPrekey = unb64(parts["signedPrekey"]),
            signedPrekeySignature = unb64(parts["signedPrekeySignature"]),
            prekeyId = optInt("prekeyId"), prekey = optBytes("prekey"),
            kyberId = optInt("kyberId"), kyber = optBytes("kyber"), kyberSignature = optBytes("kyberSignature"),
        )
        SignalSessions.processBundle(store(accountId), address(accountId), address(peerId), bundle)
    }

    fun encrypt(accountId: String, peerId: String, plainB64: String): Map<String, Any> {
        val message = SignalSessions.encrypt(store(accountId), address(accountId), address(peerId), unb64(plainB64))
        return mapOf("type" to message.type, "body" to b64(message.body))
    }

    fun decrypt(accountId: String, peerId: String, type: Number, bodyB64: String): Map<String, Any> {
        val plain = SignalSessions.decrypt(store(accountId), address(accountId), address(peerId), type.toInt(), unb64(bodyB64))
        return mapOf("plain" to b64(plain))
    }

    fun seal(accountId: String, dataB64: String): Map<String, Any> =
        mapOf("blob" to b64(DeviceSignalStore(context, accountId).sealBlob(unb64(dataB64))))

    fun open(accountId: String, blobB64: String): Map<String, Any> =
        mapOf("data" to b64(DeviceSignalStore(context, accountId).openBlob(unb64(blobB64))))

    fun hasSession(accountId: String, peerId: String): Boolean {
        return store(accountId).containsSession(address(peerId))
    }
}
