package dev.openchat.open_chat.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONObject
import org.signal.libsignal.protocol.IdentityKeyPair
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/** Account-scoped identity only. Persistent ratchet sessions are a later milestone. */
class IdentityVault(context: Context, accountId: String) {
    private val account = UUID.fromString(accountId).toString()
    private val alias = "openchat.identity.v1.$account"
    private val file = File(context.noBackupFilesDir, "signal-identity-$account.bin")
    private val atomicFile = AtomicFile(file)
    private val aad = "openchat.identity.v1:$account".toByteArray(Charsets.UTF_8)

    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun existingKey(): SecretKey = keyStore().getKey(alias, null) as? SecretKey
        ?: throw IllegalStateException("Wrapping key unavailable")

    fun initialize(): Map<String, Any> {
        if (file.exists()) return status()
        // Missing/corrupt state must never cause silent identity replacement.
        check(!keyStore().containsAlias(alias)) { "Incomplete identity state" }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).build())
        val wrappingKey = generator.generateKey()
        val identity = IdentityKeyPair.generate()
        val privateBytes = identity.serialize()
        val clear = JSONObject().put("version", 1).put("account", account)
            .put("registrationId", SecureRandom().nextInt(16380) + 1)
            .put("identity", Base64.encodeToString(privateBytes, Base64.NO_WRAP))
            .toString().toByteArray(Charsets.UTF_8)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, wrappingKey)
            cipher.updateAAD(aad)
            val encrypted = cipher.doFinal(clear)
            val output = atomicFile.startWrite()
            try {
                output.write(byteArrayOf(1))
                output.write(cipher.iv)
                output.write(encrypted)
                atomicFile.finishWrite(output)
            } catch (error: Exception) {
                atomicFile.failWrite(output)
                throw error
            }
        } finally {
            privateBytes.fill(0)
            clear.fill(0)
        }
        return status()
    }

    fun status(): Map<String, Any> {
        if (!file.exists()) {
            check(!keyStore().containsAlias(alias)) { "Identity file missing" }
            return mapOf("initialized" to false, "libraryVersion" to "0.105.0")
        }
        val bytes = atomicFile.readFully()
        check(bytes.size in 30..8192 && bytes[0] == 1.toByte()) { "Invalid identity file" }
        val key = existingKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        cipher.updateAAD(aad)
        val clear = cipher.doFinal(bytes.copyOfRange(13, bytes.size))
        try {
            val state = JSONObject(String(clear, Charsets.UTF_8))
            check(state.getInt("version") == 1 && state.getString("account") == account)
            val privateBytes = Base64.decode(state.getString("identity"), Base64.NO_WRAP)
            val identity = try { IdentityKeyPair(privateBytes) } finally { privateBytes.fill(0) }
            val fingerprint = MessageDigest.getInstance("SHA-256").digest(identity.publicKey.serialize())
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val keyInfo = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
                .getKeySpec(key, KeyInfo::class.java) as KeyInfo
            @Suppress("DEPRECATION")
            val hardware = keyInfo.isInsideSecureHardware
            return mapOf("initialized" to true, "libraryVersion" to "0.105.0",
                "fingerprint" to fingerprint, "hardwareBacked" to hardware,
                "registrationId" to state.getInt("registrationId"))
        } finally { clear.fill(0) }
    }
}
