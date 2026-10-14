package dev.openchat.open_chat.security

import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.KeyGenerator
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.signal.libsignal.protocol.DuplicateMessageException
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.InvalidMessageException
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.message.CiphertextMessage

/** Two file-backed stores talk through base64 bundle/ciphertext transport,
 *  exactly like the Supabase key/message queue carries them. */
class SessionPersistenceTest {
    private val encoder = Base64.getEncoder()
    private val decoder = Base64.getDecoder()

    private inner class Fixture {
        val dir = Files.createTempDirectory("openchat-session-test")
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        private val identities = mutableMapOf<String, IdentityKeyPair>()
        private val registrations = mutableMapOf<String, Int>()
        fun backend(name: String, aad: String): SignalStoreBackend = object : SignalStoreBackend {
            val file = dir.resolve("$name.bin").toFile()
            override fun load(): ByteArray? =
                if (file.exists()) CryptoEnvelope.open(key, aad.toByteArray(), 2, file.readBytes(), 1_000_000) else null
            override fun store(data: ByteArray) {
                val tmp = dir.resolve("$name.tmp").toFile()
                tmp.writeBytes(CryptoEnvelope.seal(key, aad.toByteArray(), 2, data))
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
                backend(name, "aad-$name"),
                identities.getOrPut(name) { IdentityKeyPair.generate() },
                registrations.getOrPut(name) { SecureRandom().nextInt(16380) + 1 },
            )
    }

    private fun transport(bundle: SignalSessions.FreshBundle): BundleParts = BundleParts(
        registrationId = bundle.registrationId,
        identityKey = decoder.decode(encoder.encodeToString(bundle.identityKey)),
        signedPrekeyId = bundle.signedPrekeyId,
        signedPrekey = decoder.decode(encoder.encodeToString(bundle.signedPrekey)),
        signedPrekeySignature = decoder.decode(encoder.encodeToString(bundle.signedPrekeySignature)),
        prekeyId = bundle.prekeys.first().first,
        prekey = decoder.decode(encoder.encodeToString(bundle.prekeys.first().second)),
        kyberId = bundle.kyber.first().first,
        kyber = decoder.decode(encoder.encodeToString(bundle.kyber.first().second)),
        kyberSignature = decoder.decode(encoder.encodeToString(bundle.kyber.first().third)),
    )

    @Test fun encryptedSessionSurvivesRestart() {
        val fixture = Fixture()
        val aliceAddress = SignalProtocolAddress("alice-account", 1)
        val bobAddress = SignalProtocolAddress("bob-account", 1)
        var alice = fixture.store("alice")
        var bob = fixture.store("bob")

        val bundle = SignalSessions.freshBundle(bob, 3, 2)
        SignalSessions.processBundle(alice, aliceAddress, bobAddress, transport(bundle))

        val first = SignalSessions.encrypt(alice, aliceAddress, bobAddress, "hello bob".toByteArray())
        assertEquals(CiphertextMessage.PREKEY_TYPE, first.type)
        assertArrayEquals("hello bob".toByteArray(), SignalSessions.decrypt(bob, bobAddress, aliceAddress, first.type, first.body))
        assertFalse("One-time prekey must be consumed", bob.containsPreKey(bundle.prekeys.first().first))
        assertTrue("Kyber prekey must be marked used", bob.hasKyberPreKeyBeenUsed(bundle.kyber.first().first))

        val reply = SignalSessions.encrypt(bob, bobAddress, aliceAddress, "hello alice".toByteArray())
        assertEquals(CiphertextMessage.WHISPER_TYPE, reply.type)
        assertArrayEquals("hello alice".toByteArray(), SignalSessions.decrypt(alice, aliceAddress, bobAddress, reply.type, reply.body))

        // Simulate app restarts: brand-new store objects over the same files.
        alice = fixture.store("alice")
        bob = fixture.store("bob")
        val second = SignalSessions.encrypt(alice, aliceAddress, bobAddress, "after restart".toByteArray())
        assertEquals(CiphertextMessage.WHISPER_TYPE, second.type)
        assertArrayEquals("after restart".toByteArray(), SignalSessions.decrypt(bob, bobAddress, aliceAddress, second.type, second.body))

        // Out-of-order delivery still works after restart.
        val one = SignalSessions.encrypt(alice, aliceAddress, bobAddress, "one".toByteArray()).body
        val two = SignalSessions.encrypt(alice, aliceAddress, bobAddress, "two".toByteArray()).body
        assertArrayEquals("two".toByteArray(), SignalSessions.decrypt(bob, bobAddress, aliceAddress, CiphertextMessage.WHISPER_TYPE, two))
        assertArrayEquals("one".toByteArray(), SignalSessions.decrypt(bob, bobAddress, aliceAddress, CiphertextMessage.WHISPER_TYPE, one))

        // Replays and tampering are rejected.
        try {
            SignalSessions.decrypt(bob, bobAddress, aliceAddress, CiphertextMessage.WHISPER_TYPE, one)
            fail("Replay must be rejected")
        } catch (_: DuplicateMessageException) { }
        val tampered = two.copyOf()
        tampered[tampered.lastIndex] = (tampered.last().toInt() xor 1).toByte()
        try {
            SignalSessions.decrypt(bob, bobAddress, aliceAddress, CiphertextMessage.WHISPER_TYPE, tampered)
            fail("Tampering must be rejected")
        } catch (_: InvalidMessageException) { }
          catch (_: DuplicateMessageException) { }
    }

    @Test fun sessionStartsWithoutOneTimePrekey() {
        val fixture = Fixture()
        val aliceAddress = SignalProtocolAddress("alice-account", 1)
        val bobAddress = SignalProtocolAddress("bob-account", 1)
        val alice = fixture.store("alice")
        val bob = fixture.store("bob")
        val bundle = SignalSessions.freshBundle(bob, 1, 1)
        // Exhaust the single one-time prekey with a first session, then start another.
        SignalSessions.processBundle(alice, aliceAddress, bobAddress, transport(bundle))
        val first = SignalSessions.encrypt(alice, aliceAddress, bobAddress, "first".toByteArray())
        SignalSessions.decrypt(bob, bobAddress, aliceAddress, first.type, first.body)

        val alice2 = fixture.store("alice2")
        val parts = transport(bundle).copy(prekeyId = null, prekey = null)
        SignalSessions.processBundle(alice2, SignalProtocolAddress("alice2-account", 1), bobAddress, parts)
        val second = SignalSessions.encrypt(alice2, SignalProtocolAddress("alice2-account", 1), bobAddress, "second".toByteArray())
        assertArrayEquals("second".toByteArray(), SignalSessions.decrypt(bob, bobAddress, SignalProtocolAddress("alice2-account", 1), second.type, second.body))
    }

    @Test fun groupSenderKeysSurviveRestartAndRotateByEpoch() {
        val fixture = Fixture()
        val aliceId = "alice-account"
        val bobId = "bob-account"
        val aliceAddress = SignalProtocolAddress(aliceId, 1)
        val bobAddress = SignalProtocolAddress(bobId, 1)
        var alice = fixture.store("alice")
        var bob = fixture.store("bob")
        SignalSessions.processBundle(
            alice,
            aliceAddress,
            bobAddress,
            transport(SignalSessions.freshBundle(bob, 2, 1)),
        )
        fun sender(group: String, epoch: Int, id: String) =
            SignalProtocolAddress("openchat-group:$group:$epoch:$id", 1)

        val group = "group-1"
        val firstSender = sender(group, 1, aliceId)
        val firstDistribution = SignalSessions.createGroupSenderKey(alice, firstSender)
        assertTrue(firstDistribution.created)
        val firstKeyEnvelope = SignalSessions.encrypt(
            alice,
            aliceAddress,
            bobAddress,
            firstDistribution.packet!!,
        )
        val firstKeyPacket = SignalSessions.decrypt(
            bob,
            bobAddress,
            aliceAddress,
            firstKeyEnvelope.type,
            firstKeyEnvelope.body,
        )
        SignalSessions.processGroupSenderKey(bob, firstSender, firstKeyPacket)
        SignalSessions.markGroupSenderKeyPublished(alice, firstSender)

        val first = SignalSessions.encryptGroup(alice, firstSender, "first group message".toByteArray())
        assertArrayEquals(
            "first group message".toByteArray(),
            SignalSessions.decryptGroup(bob, firstSender, first),
        )

        // Ratchet state and distribution identifiers are durable across app
        // restarts; the same epoch continues its chain.
        alice = fixture.store("alice")
        bob = fixture.store("bob")
        assertFalse(SignalSessions.createGroupSenderKey(alice, firstSender).created)
        val afterRestart = SignalSessions.encryptGroup(alice, firstSender, "after restart".toByteArray())
        assertArrayEquals(
            "after restart".toByteArray(),
            SignalSessions.decryptGroup(bob, firstSender, afterRestart),
        )

        // A membership change advances the epoch and therefore the sender key.
        val nextSender = sender(group, 2, aliceId)
        val nextDistribution = SignalSessions.createGroupSenderKey(alice, nextSender)
        assertTrue(nextDistribution.created)
        val nextMessage = SignalSessions.encryptGroup(
            alice,
            nextSender,
            "rotated key".toByteArray(),
        )
        try {
            SignalSessions.decryptGroup(bob, nextSender, nextMessage)
            fail("A member must not decrypt a new epoch before its key arrives")
        } catch (_: org.signal.libsignal.protocol.NoSessionException) { }
        val nextKeyEnvelope = SignalSessions.encrypt(
            alice,
            aliceAddress,
            bobAddress,
            nextDistribution.packet!!,
        )
        val nextKeyPacket = SignalSessions.decrypt(
            bob,
            bobAddress,
            aliceAddress,
            nextKeyEnvelope.type,
            nextKeyEnvelope.body,
        )
        SignalSessions.processGroupSenderKey(bob, nextSender, nextKeyPacket)
        SignalSessions.markGroupSenderKeyPublished(alice, nextSender)
        assertArrayEquals(
            "rotated key".toByteArray(),
            SignalSessions.decryptGroup(bob, nextSender, nextMessage),
        )

        try {
            SignalSessions.decryptGroup(bob, nextSender, nextMessage)
            fail("Group ciphertext replay must be rejected")
        } catch (_: DuplicateMessageException) { }
    }
}
