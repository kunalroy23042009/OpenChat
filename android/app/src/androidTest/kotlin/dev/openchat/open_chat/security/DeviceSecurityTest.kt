package dev.openchat.open_chat.security

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.security.KeyStore
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceSecurityTest {
    @Test fun nativeProtocolChecksOnDevice() {
        val result = SignalDiagnostics.run()
        assertEquals(true, result["roundTrip"])
        assertEquals(true, result["tamperRejected"])
        assertEquals(true, result["replayRejected"])
        assertEquals(true, result["outOfOrder"])
        assertEquals(true, result["identityChangeRejected"])
    }

    @Test fun identityPersistsAndTamperingFailsClosed() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val account = UUID.randomUUID().toString()
        val other = UUID.randomUUID().toString()
        val file = File(context.noBackupFilesDir, "signal-identity-$account.bin")
        try {
            val vault = IdentityVault(context, account)
            assertEquals(false, vault.status()["initialized"])
            val initialized = vault.initialize()
            assertEquals(true, initialized["initialized"])
            assertEquals(initialized["fingerprint"], IdentityVault(context, account).status()["fingerprint"])
            assertEquals(initialized["fingerprint"], vault.initialize()["fingerprint"])
            assertNotEquals(initialized["fingerprint"], IdentityVault(context, other).initialize()["fingerprint"])
            val bytes = file.readBytes()
            assertFalse(String(bytes).contains("identity"))
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
            file.writeBytes(bytes)
            var rejected = false
            try { vault.initialize() } catch (_: Exception) { rejected = true }
            assertTrue("Tampered state must not be replaced", rejected)
            assertArrayEquals(bytes, file.readBytes())
        } finally {
            for (id in listOf(account, other)) {
                File(context.noBackupFilesDir, "signal-identity-$id.bin").delete()
                KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry("openchat.identity.v1.$id")
            }
        }
    }
}
