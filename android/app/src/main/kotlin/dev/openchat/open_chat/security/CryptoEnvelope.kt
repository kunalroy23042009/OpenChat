package dev.openchat.open_chat.security

import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Self-contained AES-256-GCM envelope: version byte + 12-byte IV + ciphertext.
 *  Pure JCA so JVM unit tests exercise the exact device code path. */
object CryptoEnvelope {
    fun seal(key: SecretKey, aad: ByteArray, version: Byte, clear: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(aad)
        return byteArrayOf(version) + cipher.iv + cipher.doFinal(clear)
    }

    fun open(key: SecretKey, aad: ByteArray, version: Byte, sealed: ByteArray, maxSize: Int): ByteArray {
        check(sealed.size in 30..maxSize && sealed[0] == version) { "Invalid envelope" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed.copyOfRange(1, 13)))
        cipher.updateAAD(aad)
        return cipher.doFinal(sealed.copyOfRange(13, sealed.size))
    }
}

/** Raw-bytes persistence behind the encrypted store file. */
interface SignalStoreBackend {
    fun load(): ByteArray?
    fun store(data: ByteArray)
}
