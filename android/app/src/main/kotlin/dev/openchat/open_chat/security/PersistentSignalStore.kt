package dev.openchat.open_chat.security

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.TreeMap
import org.signal.libsignal.protocol.IdentityKey
import org.signal.libsignal.protocol.IdentityKeyPair
import org.signal.libsignal.protocol.InvalidKeyIdException
import org.signal.libsignal.protocol.NoSessionException
import org.signal.libsignal.protocol.SignalProtocolAddress
import org.signal.libsignal.protocol.ecc.ECPublicKey
import org.signal.libsignal.protocol.groups.state.SenderKeyRecord
import org.signal.libsignal.protocol.state.IdentityKeyStore
import org.signal.libsignal.protocol.state.KyberPreKeyRecord
import org.signal.libsignal.protocol.state.PreKeyRecord
import org.signal.libsignal.protocol.state.SessionRecord
import org.signal.libsignal.protocol.state.SignalProtocolStore
import org.signal.libsignal.protocol.state.SignedPreKeyRecord

/**
 * File-persisted Signal protocol store. State is a compact binary document
 * (Data streams only, so the same code runs on JVM tests and Android).
 * Callers must hold no locks; every mutation re-saves atomically.
 * Sender keys are process-local only: this pilot is 1:1 messaging.
 */
class PersistentSignalStore(
    private val backend: SignalStoreBackend,
    private val identity: IdentityKeyPair,
    private val registrationId: Int,
) : SignalProtocolStore {
    private val sessions = TreeMap<String, ByteArray>()
    private val identities = TreeMap<String, ByteArray>()
    private val preKeys = TreeMap<Int, ByteArray>()
    private val signedPreKeys = TreeMap<Int, ByteArray>()
    private val kyberPreKeys = TreeMap<Int, ByteArray>()
    private val kyberUsed = mutableSetOf<Int>()
    private val kyberBaseKeys = mutableMapOf<Pair<Int, Int>, MutableSet<ByteArrayKey>>()
    private val senderKeys = mutableMapOf<String, ByteArray>()

    init {
        backend.load()?.let { readFully(it) }
    }

    @Synchronized
    private fun save() {
        val out = ByteArrayOutputStream()
        DataOutputStream(out).use { data ->
            data.writeBytes("OCSS")
            data.writeInt(2)
            writeBytes(data, identity.serialize())
            data.writeInt(registrationId)
            writeStringMap(data, sessions)
            writeStringMap(data, identities)
            writeIntMap(data, preKeys)
            writeIntMap(data, signedPreKeys)
            writeIntMap(data, kyberPreKeys)
            data.writeInt(kyberUsed.size)
            for (id in kyberUsed) data.writeInt(id)
            data.writeInt(kyberBaseKeys.size)
            for ((pair, keys) in kyberBaseKeys) {
                data.writeInt(pair.first)
                data.writeInt(pair.second)
                data.writeInt(keys.size)
                for (key in keys) writeBytes(data, key.bytes)
            }
        }
        backend.store(out.toByteArray())
    }

    private fun readFully(raw: ByteArray) {
        DataInputStream(ByteArrayInputStream(raw)).use { data ->
            val magic = ByteArray(4)
            data.readFully(magic)
            check(magic.contentEquals("OCSS".toByteArray())) { "Unknown store" }
            check(data.readInt() == 2) { "Unsupported store version" }
            val identityBytes = readBytes(data)
            check(IdentityKeyPair(identityBytes).publicKey.serialize().contentEquals(identity.publicKey.serialize())) {
                "Store belongs to a different identity"
            }
            check(data.readInt() == registrationId) { "Registration id changed" }
            readStringMap(data, sessions)
            readStringMap(data, identities)
            readIntMap(data, preKeys)
            readIntMap(data, signedPreKeys)
            readIntMap(data, kyberPreKeys)
            repeat(data.readInt()) { kyberUsed.add(data.readInt()) }
            repeat(data.readInt()) {
                val pair = Pair(data.readInt(), data.readInt())
                val keys = mutableSetOf<ByteArrayKey>()
                repeat(data.readInt()) { keys.add(ByteArrayKey(readBytes(data))) }
                kyberBaseKeys[pair] = keys
            }
        }
    }

    private fun writeBytes(data: DataOutputStream, bytes: ByteArray) {
        data.writeInt(bytes.size)
        data.write(bytes, 0, bytes.size)
    }

    private fun readBytes(data: DataInputStream): ByteArray {
        val size = data.readInt()
        check(size in 0..4_000_000) { "Corrupt store entry" }
        return ByteArray(size).also { data.readFully(it) }
    }

    private fun writeStringMap(data: DataOutputStream, map: Map<String, ByteArray>) {
        data.writeInt(map.size)
        for ((key, value) in map) {
            writeBytes(data, key.toByteArray(Charsets.UTF_8))
            writeBytes(data, value)
        }
    }

    private fun readStringMap(data: DataInputStream, map: MutableMap<String, ByteArray>) {
        repeat(data.readInt()) {
            map[String(readBytes(data), Charsets.UTF_8)] = readBytes(data)
        }
    }

    private fun writeIntMap(data: DataOutputStream, map: Map<Int, ByteArray>) {
        data.writeInt(map.size)
        for ((key, value) in map) {
            data.writeInt(key)
            writeBytes(data, value)
        }
    }

    private fun readIntMap(data: DataInputStream, map: MutableMap<Int, ByteArray>) {
        repeat(data.readInt()) { map[data.readInt()] = readBytes(data) }
    }

    private fun addressKey(address: SignalProtocolAddress) = "${address.name}|${address.deviceId}"

    // IdentityKeyStore
    @Synchronized
    override fun getIdentityKeyPair(): IdentityKeyPair = identity

    @Synchronized
    override fun getLocalRegistrationId(): Int = registrationId

    @Synchronized
    override fun saveIdentity(address: SignalProtocolAddress, identityKey: IdentityKey): IdentityKeyStore.IdentityChange {
        val key = addressKey(address)
        val previous = identities[key]?.let { IdentityKey(it) }
        val change = if (previous == null || previous == identityKey) {
            IdentityKeyStore.IdentityChange.NEW_OR_UNCHANGED
        } else {
            IdentityKeyStore.IdentityChange.REPLACED_EXISTING
        }
        identities[key] = identityKey.serialize()
        save()
        return change
    }

    @Synchronized
    override fun isTrustedIdentity(address: SignalProtocolAddress, identityKey: IdentityKey, direction: IdentityKeyStore.Direction): Boolean {
        val known = identities[addressKey(address)]?.let { IdentityKey(it) } ?: return true
        return known == identityKey
    }

    @Synchronized
    override fun getIdentity(address: SignalProtocolAddress): IdentityKey? =
        identities[addressKey(address)]?.let { IdentityKey(it) }

    // PreKeyStore
    @Synchronized
    override fun loadPreKey(preKeyId: Int): PreKeyRecord =
        preKeys[preKeyId]?.let { PreKeyRecord(it) } ?: throw InvalidKeyIdException("No such prekey $preKeyId")

    @Synchronized
    override fun storePreKey(preKeyId: Int, record: PreKeyRecord) {
        preKeys[preKeyId] = record.serialize()
        save()
    }

    @Synchronized
    override fun containsPreKey(preKeyId: Int): Boolean = preKeys.containsKey(preKeyId)

    @Synchronized
    override fun removePreKey(preKeyId: Int) {
        if (preKeys.remove(preKeyId) != null) save()
    }

    // SessionStore
    @Synchronized
    override fun loadSession(address: SignalProtocolAddress): SessionRecord =
        sessions[addressKey(address)]?.let { SessionRecord(it) } ?: SessionRecord()

    @Synchronized
    override fun loadExistingSessions(addresses: List<SignalProtocolAddress>): List<SessionRecord> =
        addresses.map { address ->
            sessions[addressKey(address)]?.let { SessionRecord(it) } ?: throw NoSessionException("No session for $address")
        }

    @Synchronized
    override fun getSubDeviceSessions(name: String): List<Int> =
        sessions.keys.mapNotNull {
            val parts = it.split('|')
            if (parts.size == 2 && parts[0] == name) parts[1].toIntOrNull()?.takeIf { id -> id != 1 } else null
        }

    @Synchronized
    override fun storeSession(address: SignalProtocolAddress, record: SessionRecord) {
        sessions[addressKey(address)] = record.serialize()
        save()
    }

    @Synchronized
    override fun containsSession(address: SignalProtocolAddress): Boolean = sessions.containsKey(addressKey(address))

    @Synchronized
    override fun deleteSession(address: SignalProtocolAddress) {
        if (sessions.remove(addressKey(address)) != null) save()
    }

    @Synchronized
    override fun deleteAllSessions(name: String) {
        if (sessions.keys.removeIf { it.split('|').getOrNull(0) == name }) save()
    }

    // SignedPreKeyStore
    @Synchronized
    override fun loadSignedPreKey(signedPreKeyId: Int): SignedPreKeyRecord =
        signedPreKeys[signedPreKeyId]?.let { SignedPreKeyRecord(it) } ?: throw InvalidKeyIdException("No such signed prekey")

    @Synchronized
    override fun loadSignedPreKeys(): List<SignedPreKeyRecord> = signedPreKeys.values.map { SignedPreKeyRecord(it) }

    @Synchronized
    override fun storeSignedPreKey(signedPreKeyId: Int, record: SignedPreKeyRecord) {
        signedPreKeys[signedPreKeyId] = record.serialize()
        save()
    }

    @Synchronized
    override fun containsSignedPreKey(signedPreKeyId: Int): Boolean = signedPreKeys.containsKey(signedPreKeyId)

    @Synchronized
    override fun removeSignedPreKey(signedPreKeyId: Int) {
        if (signedPreKeys.remove(signedPreKeyId) != null) save()
    }

    // SenderKeyStore (process-local; unused by 1:1 pilot flows)
    @Synchronized
    override fun storeSenderKey(sender: SignalProtocolAddress, distributionId: java.util.UUID, record: SenderKeyRecord) {
        senderKeys["${addressKey(sender)}|${distributionId}"] = record.serialize()
    }

    @Synchronized
    override fun loadSenderKey(sender: SignalProtocolAddress, distributionId: java.util.UUID): SenderKeyRecord? =
        senderKeys["${addressKey(sender)}|${distributionId}"]?.let { SenderKeyRecord(it) }

    // KyberPreKeyStore
    @Synchronized
    override fun loadKyberPreKey(kyberPreKeyId: Int): KyberPreKeyRecord =
        kyberPreKeys[kyberPreKeyId]?.let { KyberPreKeyRecord(it) } ?: throw InvalidKeyIdException("No such kyber prekey")

    @Synchronized
    override fun loadKyberPreKeys(): List<KyberPreKeyRecord> = kyberPreKeys.values.map { KyberPreKeyRecord(it) }

    @Synchronized
    override fun storeKyberPreKey(kyberPreKeyId: Int, record: KyberPreKeyRecord) {
        kyberPreKeys[kyberPreKeyId] = record.serialize()
        save()
    }

    @Synchronized
    override fun containsKyberPreKey(kyberPreKeyId: Int): Boolean = kyberPreKeys.containsKey(kyberPreKeyId)

    @Synchronized
    override fun markKyberPreKeyUsed(kyberPreKeyId: Int, signedPreKeyId: Int, baseKey: ECPublicKey) {
        kyberUsed.add(kyberPreKeyId)
        val seen = kyberBaseKeys.getOrPut(Pair(kyberPreKeyId, signedPreKeyId)) { mutableSetOf() }
        if (!seen.add(ByteArrayKey(baseKey.serialize()))) {
            throw org.signal.libsignal.protocol.ReusedBaseKeyException()
        }
        save()
    }

    @Synchronized
    fun hasKyberPreKeyBeenUsed(kyberPreKeyId: Int): Boolean = kyberUsed.contains(kyberPreKeyId)

    private data class ByteArrayKey(val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean = other is ByteArrayKey && bytes.contentEquals(other.bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }
}
