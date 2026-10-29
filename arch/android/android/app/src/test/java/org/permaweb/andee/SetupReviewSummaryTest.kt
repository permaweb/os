package org.permaweb.andee

import org.junit.Assert.*
import org.junit.Test

class SetupReviewSummaryTest {
    private val wallet = "A".repeat(37) + "abcdef"

    @Test fun fullSetupShowsChoicesWithoutClaimingSubscriptionAuthentication() {
        assertEquals(listOf(
            "Profile" to "Full",
            "AI" to "ChatGPT subscription",
            "Tunnel" to "tunnel.mystical.computer",
            "Wallet" to "AAAAAA…abcdef",
        ), SetupReviewSummary.rows("andee-configurator/full", "intelligence-pool",
            listOf("https://tunnel.mystical.computer/"), wallet))
    }

    @Test fun displaysTheSelectedProviderWithoutInferringOtherConnections() {
        for ((provider, label) in listOf("apus" to "Apus", "openrouter" to "OpenRouter",
            "local-andee" to "On-device AI", "" to "Not configured", "unknown-secret" to "Custom provider")) {
            assertEquals(label, SetupReviewSummary.rows("full", provider, emptyList(), wallet).toMap()["AI"])
        }
    }

    @Test fun customTunnelPortsAreVisibleAndMissingTunnelIsExplicit() {
        assertEquals("example.com:8443", SetupReviewSummary.rows("custom", "",
            listOf("https://example.com:8443"), wallet).toMap()["Tunnel"])
        assertEquals("Not configured", SetupReviewSummary.rows("custom", "", emptyList(), wallet).toMap()["Tunnel"])
    }

    @Test fun tunnelCredentialsPathsAndQueriesNeverReachTheReview() {
        for (peer in listOf("https://user:secret@example.com", "https://example.com/?key=secret",
            "https://example.com/secret", "https://example.com/#secret", "secret", "")) {
            val rows = SetupReviewSummary.rows("full", "", listOf(peer), wallet)
            assertEquals("Address unavailable", rows.toMap()["Tunnel"])
            assertFalse(rows.toString().contains("secret"))
        }
    }

    @Test fun malformedDisplayFieldsAreNotPresentedAsValidConfiguration() {
        val rows = SetupReviewSummary.rows("https://secret?key=value", "", emptyList(), "not-a-wallet").toMap()
        assertEquals("Custom", rows["Profile"])
        assertEquals("Not specified", rows["Wallet"])
    }

    @Test fun declaredAdministratorIsDisclosedInsteadOfTheAgentWallet() {
        val admin = "B".repeat(37) + "uvwxyz"
        val rows = SetupReviewSummary.rows("full", "apus", emptyList(), wallet, admin).toMap()
        assertEquals("BBBBBB…uvwxyz", rows["Administrator"])
        assertFalse(rows.containsKey("Wallet"))
        val invalid = SetupReviewSummary.rows("full", "apus", emptyList(), wallet, "invalid").toMap()
        assertEquals("Not specified", invalid["Administrator"])
        assertFalse(invalid.containsKey("Wallet"))
    }
}
