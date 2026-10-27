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

internal data class NodeMetadata(val address: String, val locationUrl: String?)

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

    fun snapshot(ip: String?, read: (String) -> NodeMetadata?): NodeStatus {
        val local = read("http://127.0.0.1:8734$INFO") ?: return NodeStatus.booting()
        if (!addressPattern.matches(local.address)) return NodeStatus.booting()
        val configured = local.locationUrl
        if (configured != null) {
            val unavailable = NodeStatus(false, ip, "", "TUNNEL UNAVAILABLE")
            val publicOrigin = origin(configured) ?: return unavailable
            val url = publicOrigin + INFO
            val remote = read(url) ?: return unavailable
            // A reachable gateway alone is insufficient: it must reach this node.
            if (remote.address != local.address) return unavailable
            return NodeStatus(true, ip, url, "CONNECT YOUR NODE")
        }
        return if (ip == null) NodeStatus(false, null, "", "NETWORK UNAVAILABLE")
        else NodeStatus(true, ip, "http://$ip:8734$INFO", "LOCAL NETWORK NODE")
    }
}
