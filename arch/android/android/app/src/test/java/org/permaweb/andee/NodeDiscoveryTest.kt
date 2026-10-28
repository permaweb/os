package org.permaweb.andee

import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.decoder.Decoder
import org.junit.Assert.*
import org.junit.Test

class NodeDiscoveryTest {
    private val address = "A".repeat(43)
    private val origin = "https://${"a".repeat(52)}.smoke.solutions"

    @Test fun bareTunnelRootRoundTripsWithoutSubstitution() {
        val url = origin
        val rows = DiscoveryQr.rowsFor(url)
        // Decode the symbol independently of the renderer, excluding its quiet zone.
        val symbol = BitMatrix(rows.size - 8)
        for (y in 4 until rows.size - 4) for (x in 4 until rows.size - 4) {
            if (rows[y][x]) symbol.set(x - 4, y - 4)
        }
        assertEquals(url, Decoder().decode(symbol).text)
        assertTrue(rows.size > 33)
    }

    @Test fun onlyMatchingReachableNodeProducesTunnelQr() {
        val calls = mutableListOf<String>()
        val status = NodeDiscovery.snapshot("192.168.1.2") { url ->
            calls.add(url)
            NodeMetadata(address, origin)
        }
        assertTrue(status.ready)
        assertEquals(origin, status.url)
        assertEquals(listOf("http://127.0.0.1:8734${NodeDiscovery.INFO}", origin + NodeDiscovery.INFO), calls)
    }

    @Test fun unreachableOrWrongTunnelDoesNotFallBackToLan() {
        for (remote in listOf(null, NodeMetadata("B".repeat(43), origin))) {
            val status = NodeDiscovery.snapshot("192.168.1.2") { url ->
                if (url.startsWith("http://127.")) NodeMetadata(address, origin) else remote
            }
            assertFalse(status.ready)
            assertEquals("", status.url)
            assertEquals("TUNNEL UNAVAILABLE", status.label)
        }
    }

    @Test fun changedConfigurationIsReadOnEverySnapshot() {
        for (host in listOf(origin, "https://next.smoke.solutions")) {
            val status = NodeDiscovery.snapshot(null) { NodeMetadata(address, host) }
            assertEquals(host, status.url)
        }
    }

    @Test fun startingAndLocalOnlyStatesStayDistinct() {
        assertEquals(NodeStatus.booting(), NodeDiscovery.snapshot(null) { null })
        assertEquals("NETWORK UNAVAILABLE", NodeDiscovery.snapshot(null) { NodeMetadata(address, null) }.label)
        val local = NodeDiscovery.snapshot("192.168.1.2") { NodeMetadata(address, null) }
        assertTrue(local.ready)
        assertEquals("LOCAL NETWORK NODE", local.label)
        assertEquals("http://192.168.1.2:8734", local.url)
        assertFalse(DiscoveryQr.rowsFor("").any { it.any { cell -> cell } })
    }

    @Test fun credentialsQueriesPathsAndPlaceholdersAreNotQrPayloads() {
        for (value in listOf("https://owner:secret@example.com", "https://example.com/?key=secret",
            "https://example.com/#secret", "https://example.com/path", "file:///etc/passwd",
            "https://**[base32 encoded node address]**.smoke.solutions")) {
            assertNull(NodeDiscovery.origin(value))
            val status = NodeDiscovery.snapshot("192.168.1.2") { NodeMetadata(address, value) }
            assertFalse(status.ready)
            assertEquals("", status.url)
        }
    }
}
