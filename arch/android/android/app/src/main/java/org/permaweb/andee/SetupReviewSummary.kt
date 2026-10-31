package org.permaweb.andee

import java.net.URI

/** Display only the choices the import screen needs; credentials never enter this formatter. */
internal object SetupReviewSummary {
    fun rows(profile: String, provider: String, tunnelPeers: List<String>, operator: String, admin: String? = null): List<Pair<String, String>> {
        val profileName = profile.substringAfterLast('/').takeIf {
            it.length in 1..48 && it.all { char -> char.isLetterOrDigit() || char in "-+ " }
        }?.replace('-', ' ')?.replaceFirstChar { it.titlecase() } ?: "Custom"
        val ai = when (provider) {
            "intelligence-pool" -> "ChatGPT subscription"
            "apus" -> "Apus"
            "openrouter" -> "OpenRouter"
            "openai" -> "OpenAI"
            "anthropic" -> "Anthropic"
            "local-andee" -> "On-device AI"
            "" -> "Not configured"
            else -> "Custom provider"
        }
        val tunnel = if (tunnelPeers.isEmpty()) "Not configured" else tunnelPeers.map { peer ->
            NodeDiscovery.origin(peer)?.let { URI(it).rawAuthority } ?: "Address unavailable"
        }.distinct().joinToString(" · ")
        val address = admin ?: operator
        val wallet = if (Regex("[A-Za-z0-9_-]{43}").matches(address)) {
            "${address.take(6)}…${address.takeLast(6)}"
        } else "Not specified"
        val walletLabel = if (admin != null) "Administrator" else "Wallet"
        return listOf("Profile" to profileName, "AI" to ai, "Tunnel" to tunnel, walletLabel to wallet)
    }
}
