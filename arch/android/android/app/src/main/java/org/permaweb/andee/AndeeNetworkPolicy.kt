package org.permaweb.andee

import java.net.Inet6Address
import java.net.InetAddress

/** Numeric destination policy for the v1 public-outbound network capability. */
internal class AndeeNetworkPolicy(
    dnsServers: Collection<AndeeIpAddress>,
    localAddresses: Collection<AndeeIpAddress>,
    localPrefixes: Collection<AndeeIpPrefix>,
) {
    private val dnsServers = dnsServers.map(AndeeIpAddress::normalized).toSet()
    private val localAddresses = localAddresses
        .map { it.normalized().copy(scopeId = 0) }
        .toSet()
    private val localPrefixes = localPrefixes.toList()

    fun allows(
        address: ByteArray,
        port: Int,
        scopeId: Int,
    ): Boolean {
        if (port !in 1..65535 || scopeId < 0) return false
        val rawDestination = runCatching {
            AndeeIpAddress(address.toList(), scopeId)
        }.getOrNull() ?: return false
        val destination = rawDestination.normalized()
        if (rawDestination.bytes.size != destination.bytes.size && scopeId != 0) return false
        if (destination.copy(scopeId = 0) in localAddresses) return false
        if (destination in dnsServers && port == DNS_PORT) return true
        if (destination.bytes.size == IPV4_BYTES && destination.scopeId != 0) return false
        if (destination.bytes.size == IPV6_BYTES && destination.scopeId != 0) return false
        if (localPrefixes.any { it.contains(destination) }) return false
        return publicDestinationBlocks.none { it.contains(destination) }
    }

    private companion object {
        const val DNS_PORT = 53
        const val IPV4_BYTES = 4
        const val IPV6_BYTES = 16

        val publicDestinationBlocks = listOf(
            // IPv4 special-use, private, local, multicast, and reserved space.
            "0.0.0.0/8",
            "10.0.0.0/8",
            "100.64.0.0/10",
            "127.0.0.0/8",
            "169.254.0.0/16",
            "172.16.0.0/12",
            "192.0.0.0/24",
            "192.0.2.0/24",
            "192.88.99.0/24",
            "192.168.0.0/16",
            "198.18.0.0/15",
            "198.51.100.0/24",
            "203.0.113.0/24",
            "224.0.0.0/4",
            "240.0.0.0/4",
            // IPv6 translation, local, special-use, documentation, and multicast space.
            "::/96",
            "64:ff9b::/96",
            "64:ff9b:1::/48",
            "100::/64",
            "2001::/32",
            "2001:2::/48",
            "2001:10::/28",
            "2001:20::/28",
            "2001:db8::/32",
            "2002::/16",
            "3fff::/20",
            "5f00::/16",
            "fc00::/7",
            "fe80::/10",
            "fec0::/10",
            "ff00::/8",
        ).map(AndeeIpPrefix::parse)
    }
}

internal data class AndeeIpAddress(
    val bytes: List<Byte>,
    val scopeId: Int = 0,
) {
    init {
        require(bytes.size == IPV4_BYTES || bytes.size == IPV6_BYTES) {
            "IP addresses must contain 4 or 16 bytes"
        }
        require(scopeId >= 0) { "IP scope IDs cannot be negative" }
    }

    fun normalized(): AndeeIpAddress = if (isIpv4Mapped()) {
        AndeeIpAddress(bytes.takeLast(IPV4_BYTES))
    } else {
        this
    }

    fun render(): String {
        val rendered = InetAddress.getByAddress(bytes.toByteArray()).hostAddress
        return if (bytes.size == IPV6_BYTES && scopeId != 0) "$rendered%$scopeId" else rendered
    }

    private fun isIpv4Mapped(): Boolean =
        bytes.size == IPV6_BYTES &&
            bytes.take(10).all { it == 0.toByte() } &&
            bytes[10] == 0xff.toByte() &&
            bytes[11] == 0xff.toByte()

    companion object {
        private const val IPV4_BYTES = 4
        private const val IPV6_BYTES = 16

        fun from(address: InetAddress): AndeeIpAddress = AndeeIpAddress(
            address.address.toList(),
            (address as? Inet6Address)?.scopeId ?: 0,
        )
    }
}

internal data class AndeeIpPrefix(
    val address: AndeeIpAddress,
    val prefixLength: Int,
) {
    init {
        require(prefixLength in 0..address.bytes.size * Byte.SIZE_BITS) {
            "invalid IP prefix length"
        }
    }

    fun contains(candidate: AndeeIpAddress): Boolean {
        val normalizedAddress = address.normalized()
        val normalizedCandidate = candidate.normalized()
        if (normalizedAddress.bytes.size != normalizedCandidate.bytes.size) return false
        var remaining = prefixLength
        for (index in normalizedAddress.bytes.indices) {
            if (remaining == 0) return true
            val bits = minOf(Byte.SIZE_BITS, remaining)
            val mask = (0xff shl (Byte.SIZE_BITS - bits)) and 0xff
            if (
                (normalizedAddress.bytes[index].toInt() and mask) !=
                (normalizedCandidate.bytes[index].toInt() and mask)
            ) return false
            remaining -= bits
        }
        return true
    }

    companion object {
        fun parse(value: String): AndeeIpPrefix {
            val (address, prefix) = value.split('/', limit = 2)
            return AndeeIpPrefix(
                AndeeIpAddress.from(InetAddress.getByName(address)),
                prefix.toInt(),
            )
        }
    }
}
