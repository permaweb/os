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

    @Test fun explicitManifestDeviceKeepsEntryAndAssetsWithinThePinnedRelease() {
        val base = "https://bundler.mystical.computer/GKWEPkK-GUJYx3JTAJ-aCR6ZgshVW9naSueDZOeiXhc~manifest@1.0/"
        val manifest = ConfiguratorLocation(base)
        assertEquals(base + "index.html", manifest.entryUrl)
        assertEquals(manifest.entryUrl, ConfiguratorLocation(base.trimEnd('/')).entryUrl)
        assertTrue(manifest.contains(manifest.entryUrl))
        assertTrue(manifest.contains(base + "src/app.js?v=20260929-standalone-market"))
        assertTrue(manifest.contains(base + "styles.css?v=20260929-standalone-market"))
        for (url in listOf(
            "https://bundler.mystical.computer/$tx~manifest@1.0/index.html",
            base.replace("bundler.mystical.computer", "other.example") + "index.html",
            base + "../other/index.html",
            base + "%2e%2e/other/index.html",
        )) assertFalse(url, manifest.contains(url))
    }
}
