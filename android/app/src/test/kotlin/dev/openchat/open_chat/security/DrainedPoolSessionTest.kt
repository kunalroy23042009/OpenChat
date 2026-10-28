package dev.openchat.open_chat.security

import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.KeyGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.message.CiphertextMessage
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/**
 * The drained-pool path the server's claim_key_bundle now serves: a bundle
 * with no one-time EC prekey (id/key null) must still establish working
 * sessions, and several senders may share the peer's same long-lived
 * signed Kyber prekey.
 */
class DrainedPoolSessionTest {
    private val encoder = Base64.getEncoder()
    private val decoder = Base64.getDecoder()

    private inner class Fixture {
        val dir = Files.createTempDirectory("openchat-drained-test")
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        private val identities = mutableMapOf<String, IdentityKeyPair>()
        private val registrations = mutableMapOf<String, Int>()
        fun backend(name: String): SignalStoreBackend = object : SignalStoreBackend {
            val file = dir.resolve("$name.bin").toFile()
            override fun load(): ByteArray? =
                if (file.exists()) CryptoEnvelope.open(key, "aad-$name".toByteArray(), 2, file.readBytes(), 1_000_000) else null
            override fun store(data: ByteArray) {
                val tmp = dir.resolve("$name.tmp").toFile()
                tmp.writeBytes(CryptoEnvelope.seal(key, "aad-$name".toByteArray(), 2, data))
                try {
                    Files.move(
                        tmp.toPath(),
                        file.toPath(),
                        StandardCopyOption.REPLACE_EXISTING,
                        StandardCopyOption.ATOMIC_MOVE,
                    )
                } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                    Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
                }
            }
        }
        fun store(name: String): PersistentSignalStore =
            PersistentSignalStore(
                backend(name),
                identities.getOrPut(name) { IdentityKeyPair.generate() },
                registrations.getOrPut(name) { SecureRandom().nextInt(16380) + 1 },
            )
    }

    /** Bob's bundle with the one-time EC pool fully drained: only the
     *  long-lived signed prekey + signed Kyber prekey are available. */
    private fun bobParts(store: PersistentSignalStore): BundleParts {
        val signed = ECKeyPair.generate()
        val signature = store.identityKeyPair.privateKey.calculateSignature(signed.publicKey.serialize())
        val kyber = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
        val kyberSignature = store.identityKeyPair.privateKey.calculateSignature(kyber.publicKey.serialize())
        store.storeSignedPreKey(2, SignedPreKeyRecord(2, System.currentTimeMillis(), signed, signature))
        store.storeKyberPreKey(3, KyberPreKeyRecord(3, System.currentTimeMillis(), kyber, kyberSignature))
        return BundleParts(
            registrationId = store.localRegistrationId,
            identityKey = decoder.decode(encoder.encodeToString(store.identityKeyPair.publicKey.serialize())),
            signedPrekeyId = 2,
            signedPrekey = decoder.decode(encoder.encodeToString(signed.publicKey.serialize())),
            signedPrekeySignature = decoder.decode(encoder.encodeToString(signature)),
            prekeyId = null,
            prekey = null,
            kyberId = 3,
            kyber = decoder.decode(encoder.encodeToString(kyber.publicKey.serialize())),
            kyberSignature = decoder.decode(encoder.encodeToString(kyberSignature)),
        )
    }

    @Test fun sessionWithoutOneTimePrekeyRoundTrips() {
        val fixture = Fixture()
        val bob = fixture.store("bob")
        val parts = bobParts(bob)
        val bobAddress = SignalProtocolAddress("bob", 1)

        fun newSender(name: String): PersistentSignalStore {
            val store = fixture.store(name)
            SignalSessions.processBundle(store, SignalProtocolAddress(name, 1), bobAddress, parts)
            return store
        }

        val alice = newSender("alice")
        val aliceAddress = SignalProtocolAddress("alice", 1)
        val hello = "hello with no one-time prekey".toByteArray()
        val sent = SignalSessions.encrypt(alice, aliceAddress, bobAddress, hello)
        assertEquals(CiphertextMessage.PREKEY_TYPE, sent.type)
        assertTrue(
            SignalSessions.decrypt(bob, bobAddress, aliceAddress, sent.type, sent.body)
                .contentEquals(hello),
        )

        // A second sender claims the SAME (persistent) Kyber prekey: what
        // the server hands to every sender once the one-time pool drains.
        val carol = newSender("carol")
        val carolAddress = SignalProtocolAddress("carol", 1)
        val hi = "carol here".toByteArray()
        val sent2 = SignalSessions.encrypt(carol, carolAddress, bobAddress, hi)
        assertTrue(
            SignalSessions.decrypt(bob, bobAddress, carolAddress, sent2.type, sent2.body)
                .contentEquals(hi),
        )

        // Bob replies on both sessions.
        val replyA = SignalSessions.encrypt(bob, bobAddress, aliceAddress, "hey alice".toByteArray())
        assertTrue(
            SignalSessions.decrypt(alice, aliceAddress, bobAddress, replyA.type, replyA.body)
                .decodeToString() == "hey alice",
        )
        val replyC = SignalSessions.encrypt(bob, bobAddress, carolAddress, "hey carol".toByteArray())
        assertTrue(
            SignalSessions.decrypt(carol, carolAddress, bobAddress, replyC.type, replyC.body)
                .decodeToString() == "hey carol",
        )
    }
}
