package dev.openchat.open_chat.security

import org.signal.libsignal.protocol.DuplicateMessageException
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.InvalidMessageException
import org.signal.libsignal.protocol.SessionBuilder
import org.signal.libsignal.protocol.SessionCipher
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.UntrustedIdentityException
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyPair
import org.signal.libsignal.protocol.kem.KEMKeyType
import org.signal.libsignal.protocol.message.PreKeySignalMessage
import org.signal.libsignal.protocol.message.SignalMessage
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyBundle
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SignedPreKeyRecord
import org.signal.libsignal.protocol.state.impl.InMemorySignalProtocolStore
import java.security.SecureRandom

/** Isolated local compatibility checks. These ephemeral stores never carry user messages. */
object SignalDiagnostics {
    private fun newStore() = InMemorySignalProtocolStore(IdentityKeyPair.generate(), SecureRandom().nextInt(16380) + 1)

    private fun bundle(store: InMemorySignalProtocolStore): PreKeyBundle {
        val pre = ECKeyPair.generate()
        val signed = ECKeyPair.generate()
        val signature = store.identityKeyPair.privateKey.calculateSignature(signed.publicKey.serialize())
        val kyber = KEMKeyPair.generate(KEMKeyType.KYBER_1024)
        val kyberSignature = store.identityKeyPair.privateKey.calculateSignature(kyber.publicKey.serialize())
        store.storePreKey(1, PreKeyRecord(1, pre))
        store.storeSignedPreKey(2, SignedPreKeyRecord(2, System.currentTimeMillis(), signed, signature))
        store.storeKyberPreKey(3, KyberPreKeyRecord(3, System.currentTimeMillis(), kyber, kyberSignature))
        return PreKeyBundle(store.localRegistrationId, 1, 1, pre.publicKey, 2, signed.publicKey,
            signature, store.identityKeyPair.publicKey, 3, kyber.publicKey, kyberSignature)
    }

    fun run(): Map<String, Any> {
        val alice = newStore()
        val bob = newStore()
        val aliceAddress = SignalProtocolAddress("openchat-selftest-alice", 1)
        val bobAddress = SignalProtocolAddress("openchat-selftest-bob", 1)
        SessionBuilder(alice, bobAddress, aliceAddress).process(bundle(bob))
        val sender = SessionCipher(alice, aliceAddress, bobAddress)
        val receiver = SessionCipher(bob, bobAddress, aliceAddress)
        val hello = "OpenChat local Signal check".toByteArray()
        val first = sender.encrypt(hello)
        check(receiver.decrypt(PreKeySignalMessage(first.serialize())).contentEquals(hello))
        check(!bob.containsPreKey(1))
        check(bob.hasKyberPreKeyBeenUsed(3))
        val reply = receiver.encrypt("reply".toByteArray())
        check(String(sender.decrypt(SignalMessage(reply.serialize()))) == "reply")

        val firstOrdered = sender.encrypt("one".toByteArray()).serialize()
        val secondOrdered = sender.encrypt("two".toByteArray()).serialize()
        check(String(receiver.decrypt(SignalMessage(secondOrdered))) == "two")
        check(String(receiver.decrypt(SignalMessage(firstOrdered))) == "one")
        var replayRejected = false
        try { receiver.decrypt(SignalMessage(firstOrdered)) } catch (_: DuplicateMessageException) { replayRejected = true }
        check(replayRejected)

        val original = sender.encrypt("integrity".toByteArray()).serialize()
        val tampered = original.copyOf()
        tampered[tampered.lastIndex] = (tampered.last().toInt() xor 1).toByte()
        var tamperRejected = false
        try { receiver.decrypt(SignalMessage(tampered)) } catch (_: InvalidMessageException) { tamperRejected = true }
        check(tamperRejected)
        check(String(receiver.decrypt(SignalMessage(original))) == "integrity")

        var identityChangeRejected = false
        try { SessionBuilder(alice, bobAddress, aliceAddress).process(bundle(newStore())) }
        catch (_: UntrustedIdentityException) { identityChangeRejected = true }
        check(identityChangeRejected)
        return mapOf("roundTrip" to true, "oneTimePreKeyConsumed" to true,
            "outOfOrder" to true, "replayRejected" to replayRejected,
            "tamperRejected" to tamperRejected, "identityChangeRejected" to identityChangeRejected,
            "libraryVersion" to "0.105.0")
    }
}
