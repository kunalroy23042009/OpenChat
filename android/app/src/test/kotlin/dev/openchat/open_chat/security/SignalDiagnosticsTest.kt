package dev.openchat.open_chat.security

import org.junit.Assert.assertEquals
import org.junit.Test

class SignalDiagnosticsTest {
    @Test fun protocolChecks() {
        val result = SignalDiagnostics.run()
        for (name in listOf("roundTrip", "oneTimePreKeyConsumed", "outOfOrder", "replayRejected", "tamperRejected", "identityChangeRejected")) {
            assertEquals(name, true, result[name])
        }
    }
}
