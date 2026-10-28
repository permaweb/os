package org.permaweb.andee

import java.net.URI

internal data class NodeStatus(
    val ready: Boolean,
    val ip: String?,
    val url: String,
    val label: String,
) {
    companion object {
        fun booting() = NodeStatus(false, null, "", "NODE STARTING")
    }
}

internal data class NodeMetadata(
    val address: String,
    val locationUrl: String?,
    val committer: String? = null,
    val tunnelPeer: String? = null,
)

/** Presentation of existing meta@1.0 data; no tunnel or identity is created here. */
internal object NodeDiscovery {
    const val INFO = "/~meta@1.0/info"
    private val addressPattern = Regex("[A-Za-z0-9_-]{43}")

    fun origin(value: String): String? = try {
        val uri = URI(value)
        if (value.length > 512 || uri.scheme !in listOf("http", "https") ||
            uri.host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawQuery != null ||
            uri.rawFragment != null || uri.rawPath !in listOf("", "/") ||
            uri.port !in -1..65535 || uri.port == 0
        ) null else "${uri.scheme}://${uri.rawAuthority}"
    } catch (_: Exception) { null }

    private fun tunnelOrigin(committer: String?, peer: String): String? {
        // meta already reports HyperBEAM's DNS-safe committer. Do not re-encode identity.
        if (committer == null || !Regex("uri-did-ar-[a-z0-9-]{52}").matches(committer)) return null
        val provider = origin(peer)?.let(::URI) ?: return null
        if (!provider.host.contains('.') || provider.host.contains(':') ||
            provider.host.split('.').any { !Regex("[a-z0-9](?:[a-z0-9-]*[a-z0-9])?").matches(it) } ||
            provider.host.all { it.isDigit() || it == '.' }
        ) return null
        return origin("${provider.scheme}://$committer.${provider.rawAuthority}")
    }

    fun snapshot(ip: String?, read: (String) -> NodeMetadata?): NodeStatus {
        val local = read("http://127.0.0.1:8734$INFO") ?: return NodeStatus.booting()
        if (!addressPattern.matches(local.address)) return NodeStatus.booting()
        val configured = local.locationUrl ?: local.tunnelPeer?.let {
            tunnelOrigin(local.committer, it) ?: ""
        }
        if (configured != null) {
            val unavailable = NodeStatus(false, ip, "", "TUNNEL UNAVAILABLE")
            val publicOrigin = origin(configured) ?: return unavailable
            val remote = read(publicOrigin + INFO) ?: return unavailable
            // A reachable gateway alone is insufficient: it must reach this node.
            if (remote.address != local.address) return unavailable
            return NodeStatus(true, ip, publicOrigin, "CONNECT YOUR NODE")
        }
        return if (ip == null) NodeStatus(false, null, "", "NETWORK UNAVAILABLE")
        else NodeStatus(true, ip, "http://$ip:8734", "LOCAL NETWORK NODE")
    }
}
