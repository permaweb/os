package org.permaweb.andee

import org.junit.Assert.*
import org.junit.Test

class ConfiguratorLocationTest {
    private val tx = "A".repeat(43)
    private val location = ConfiguratorLocation("https://arweave.net/$tx/")

    @Test fun opensTheExplicitEntryWithinTheSelectedManifest() {
        val entry = "https://arweave.net/$tx/index.html"
        assertEquals(entry, location.entryUrl)
        assertEquals(entry, ConfiguratorLocation("https://arweave.net/$tx").entryUrl)
        assertTrue(location.contains(entry))
    }

    @Test fun allowsOnlyTheSelectedManifestAndItsSandbox() {
        assertTrue(location.contains("https://arweave.net/$tx/"))
        assertTrue(location.contains("https://arweave.net/$tx/src/app.js?v=1"))
        assertTrue(location.contains("https://${"a".repeat(52)}.arweave.net/index.html"))
        for (url in listOf(
            "https://arweave.net/${tx}other/",
            "https://arweave.net/$tx/../other/",
            "https://arweave.net/$tx/%2e%2e/other/",
            "https://arweave.net.evil.example/$tx/",
            "https://other.arweave.net/",
            "https://user@arweave.net/$tx/",
            "http://arweave.net/$tx/",
            "https://${"a".repeat(52)}.arweave.net:8443/",
            "javascript:alert(1)",
        )) assertFalse(url, location.contains(url))
    }

    @Test fun explicitLocalReviewBuildStaysWithinItsOwnOriginAndPath() {
        val preview = ConfiguratorLocation("http://127.0.0.1:5497/configurator/")
        assertEquals("http://127.0.0.1:5497/configurator/index.html", preview.entryUrl)
        assertTrue(preview.contains("http://127.0.0.1:5497/configurator/index.html"))
        assertFalse(preview.contains("http://127.0.0.1:5498/configurator/"))
        assertFalse(preview.contains("http://127.0.0.1:5497/other/"))
    }
}
