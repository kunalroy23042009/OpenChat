package dev.openchat.open_chat.security

import java.security.SecureRandom
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.kem.KEMPublicKey
import org.signal.libsignal.protocol.message.CiphertextMessage
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SignalMessage
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyBundle
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/** Public key material exchanged through the server. Raw bytes only. */
data class BundleParts(
    val registrationId: Int,
    val identityKey: ByteArray,
    val signedPrekeyId: Int,
    val signedPrekey: ByteArray,
    val signedPrekeySignature: ByteArray,
    val prekeyId: Int?,
    val prekey: ByteArray?,
    val kyberId: Int?,
    val kyber: ByteArray?,
    val kyberSignature: ByteArray?,
)

data class EncryptedMessage(val type: Int, val body: ByteArray)

/** Protocol operations over a persistent store. No Android APIs: JVM tests
 *  run this exact code against file-backed stores. */
object SignalSessions {
    private val random = SecureRandom()

    fun freshBundle(store: PersistentSignalStore, ecCount: Int, kyberCount: Int): FreshBundle {
        require(ecCount in 1..50 && kyberCount in 1..10) { "Invalid pool sizes" }
        val identity = store.identityKeyPair
        val signed = ECKeyPair.generate()
        val signature = identity.privateKey.calculateSignature(signed.publicKey.serialize())
        val signedId = unusedId(store::containsSignedPreKey)
        store.storeSignedPreKey(signedId, SignedPreKeyRecord(signedId, System.currentTimeMillis(), signed, signature))
        val prekeys = (1..ecCount).map {
            val pair = ECKeyPair.generate()
            val id = unusedId(store::containsPreKey)
            store.storePreKey(id, PreKeyRecord(id, pair))
            id to pair.publicKey.serialize()
        }
        val kybers = (1..kyberCount).map {
            val pair = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
            val kyberSignature = identity.privateKey.calculateSignature(pair.publicKey.serialize())
            val id = unusedId(store::containsKyberPreKey)
            store.storeKyberPreKey(id, KyberPreKeyRecord(id, System.currentTimeMillis(), pair, kyberSignature))
            Triple(id, pair.publicKey.serialize(), kyberSignature)
        }
        return FreshBundle(
            identity.publicKey.serialize(), store.localRegistrationId,
            signedId, signed.publicKey.serialize(), signature, prekeys, kybers,
        )
    }

    fun processBundle(store: PersistentSignalStore, local: SignalProtocolAddress, remote: SignalProtocolAddress, parts: BundleParts) {
        if (store.containsSession(remote)) return
        val kyberBytes = parts.kyber ?: throw IllegalArgumentException("Contact must reopen the app to refresh one-time keys")
        val kyberSignature = parts.kyberSignature ?: throw IllegalArgumentException("Contact must reopen the app to refresh one-time keys")
        val kyberId = parts.kyberId ?: throw IllegalArgumentException("Contact must reopen the app to refresh one-time keys")
        val bundle = PreKeyBundle(
            parts.registrationId, remote.deviceId,
            parts.prekeyId ?: -1, parts.prekey?.let { org.signal.libsignal.protocol.ecc.ECPublicKey(it) },
            parts.signedPrekeyId, org.signal.libsignal.protocol.ecc.ECPublicKey(parts.signedPrekey),
            parts.signedPrekeySignature, IdentityKey(parts.identityKey),
            kyberId,
            KEMPublicKey(kyberBytes),
            kyberSignature,
        )
        SessionBuilder(store, remote, local).process(bundle)
    }

    fun encrypt(store: PersistentSignalStore, from: SignalProtocolAddress, to: SignalProtocolAddress, plain: ByteArray): EncryptedMessage {
        require(plain.size in 1..4000) { "Message size out of bounds" }
        val message = SessionCipher(store, from, to).encrypt(plain)
        return EncryptedMessage(message.type, message.serialize())
    }

    fun decrypt(store: PersistentSignalStore, me: SignalProtocolAddress, peer: SignalProtocolAddress, type: Int, body: ByteArray): ByteArray {
        val cipher = SessionCipher(store, me, peer)
        return when (type) {
            CiphertextMessage.PREKEY_TYPE -> cipher.decrypt(PreKeySignalMessage(body))
            CiphertextMessage.WHISPER_TYPE -> cipher.decrypt(SignalMessage(body))
            else -> throw IllegalArgumentException("Unsupported message type")
        }
    }

    private fun unusedId(contains: (Int) -> Boolean): Int {
        repeat(1000) {
            val id = random.nextInt(1 shl 24)
            if (!contains(id)) return id
        }
        throw IllegalStateException("Key id space exhausted")
    }

    data class FreshBundle(
        val identityKey: ByteArray,
        val registrationId: Int,
        val signedPrekeyId: Int,
        val signedPrekey: ByteArray,
        val signedPrekeySignature: ByteArray,
        val prekeys: List<Pair<Int, ByteArray>>,
        val kyber: List<Triple<Int, ByteArray, ByteArray>>,
    )
}
