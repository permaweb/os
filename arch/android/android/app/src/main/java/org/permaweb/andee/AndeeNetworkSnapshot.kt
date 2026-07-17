package org.permaweb.andee

import android.content.Context
import android.net.ConnectivityManager
import java.net.NetworkInterface

/** Immutable view of resolver and interface state used for one command. */
internal data class AndeeNetworkSnapshot(
    val dnsServers: List<AndeeIpAddress>,
    val localAddresses: Set<AndeeIpAddress>,
    val localPrefixes: Set<AndeeIpPrefix>,
) {
    val policy = AndeeNetworkPolicy(dnsServers, localAddresses, localPrefixes)

    val resolverConfiguration: String = buildString {
        dnsServers.forEach { append("nameserver ").append(it.render()).append('\n') }
        append("options timeout:2 attempts:2\n")
    }

    companion object {
        fun capture(context: Context): AndeeNetworkSnapshot {
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
            val activeNetwork = connectivity.activeNetwork
                ?: throw ExecutionFailure(503, "network-unavailable")
            val links = connectivity.getLinkProperties(activeNetwork)
                ?: throw ExecutionFailure(503, "network-properties-unavailable")
            val dnsServers = links.dnsServers
                .distinctBy { it.address.toList() to (it as? java.net.Inet6Address)?.scopeId }
                .take(MAX_DNS_SERVERS)
                .map(AndeeIpAddress::from)
            if (dnsServers.isEmpty()) {
                throw ExecutionFailure(503, "network-resolver-unavailable")
            }

            val localAddresses = mutableSetOf<AndeeIpAddress>()
            val localPrefixes = mutableSetOf<AndeeIpPrefix>()
            links.linkAddresses.forEach { link ->
                val address = AndeeIpAddress.from(link.address)
                localAddresses += address.copy(scopeId = 0)
                if (link.prefixLength > 0) {
                    localPrefixes += AndeeIpPrefix(address.copy(scopeId = 0), link.prefixLength)
                }
            }
            links.routes
                .filter { route -> !route.hasGateway() && route.destination.prefixLength > 0 }
                .forEach { route ->
                    localPrefixes += AndeeIpPrefix(
                        AndeeIpAddress.from(route.destination.address).copy(scopeId = 0),
                        route.destination.prefixLength,
                    )
                }

            // A listener bound to 0.0.0.0 or :: can also be reached through a
            // non-active device interface. Deny every address and attached prefix.
            runCatching { NetworkInterface.getNetworkInterfaces()?.toList().orEmpty() }
                .getOrDefault(emptyList())
                .forEach { networkInterface ->
                    runCatching { networkInterface.interfaceAddresses.toList() }
                        .getOrDefault(emptyList())
                        .forEach { interfaceAddress ->
                            val address = AndeeIpAddress.from(interfaceAddress.address)
                            localAddresses += address.copy(scopeId = 0)
                            if (interfaceAddress.networkPrefixLength > 0) {
                                localPrefixes += AndeeIpPrefix(
                                    address.copy(scopeId = 0),
                                    interfaceAddress.networkPrefixLength.toInt(),
                                )
                            }
                        }
                }

            return AndeeNetworkSnapshot(dnsServers, localAddresses, localPrefixes)
        }

        private const val MAX_DNS_SERVERS = 8
    }
}
