package org.permaweb.andee

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AndeeNetworkPolicyTest {
    @Test
    fun allowsPublicIpv4AndIpv6() {
        val policy = policy()

        assertTrue(policy.allows(address("1.1.1.1"), 443, 0))
        assertTrue(policy.allows(address("2606:4700:4700::1111"), 443, 0))
    }

    @Test
    fun deniesSpecialAndPrivateDestinations() {
        val policy = policy()
        listOf(
            "0.0.0.0",
            "10.0.0.1",
            "100.64.0.1",
            "127.0.0.1",
            "169.254.169.254",
            "172.31.0.1",
            "192.168.1.1",
            "198.18.0.1",
            "203.0.113.1",
            "224.0.0.1",
            "255.255.255.255",
            "::1",
            "64:ff9b::808:808",
            "2001:db8::1",
            "2002:0808:0808::1",
            "fc00::1",
            "fe80::1",
            "ff02::1",
        ).forEach { destination ->
            assertFalse(destination, policy.allows(address(destination), 443, 0))
        }
    }

    @Test
    fun enforcesNonOctetPrefixBoundaries() {
        val policy = policy()

        assertTrue(policy.allows(address("100.63.255.255"), 443, 0))
        assertFalse(policy.allows(address("100.64.0.0"), 443, 0))
        assertFalse(policy.allows(address("100.127.255.255"), 443, 0))
        assertTrue(policy.allows(address("100.128.0.0"), 443, 0))
        assertTrue(policy.allows(address("172.15.255.255"), 443, 0))
        assertFalse(policy.allows(address("172.16.0.0"), 443, 0))
        assertFalse(policy.allows(address("172.31.255.255"), 443, 0))
        assertTrue(policy.allows(address("172.32.0.0"), 443, 0))
    }

    @Test
    fun deniesEveryCurrentInterfaceAndAttachedPrefix() {
        val policy = policy(
            localAddresses = setOf(ip("2001:4860::1234")),
            localPrefixes = setOf(prefix("8.8.8.0/24"), prefix("2001:4860::/64")),
        )

        assertFalse(policy.allows(address("8.8.8.8"), 443, 0))
        assertFalse(policy.allows(address("2001:4860::1234"), 443, 0))
        assertFalse(policy.allows(address("2001:4860::5678"), 443, 0))
        assertTrue(policy.allows(address("8.8.4.4"), 443, 0))
    }

    @Test
    fun permitsOnlyExactActiveDnsEndpoint() {
        val privateDns = ip("192.168.50.1")
        val policy = policy(dnsServers = setOf(privateDns))

        assertTrue(policy.allows(address("192.168.50.1"), 53, 0))
        assertFalse(policy.allows(address("192.168.50.1"), 443, 0))
        assertFalse(policy.allows(address("192.168.50.2"), 53, 0))

        val localResolver = policy(
            dnsServers = setOf(privateDns),
            localAddresses = setOf(privateDns),
        )
        assertFalse(localResolver.allows(address("192.168.50.1"), 53, 0))
    }

    @Test
    fun canonicalizesMappedIpv6BeforePolicy() {
        assertFalse(policy().allows(mapped("127.0.0.1"), 443, 0))
        assertTrue(policy().allows(mapped("1.1.1.1"), 443, 0))
        assertFalse(policy().allows(mapped("1.1.1.1"), 443, 7))
    }

    @Test
    fun scopesAreLimitedToExactDnsExceptions() {
        val scopedDns = ip("fe80::53", 7)
        val policy = policy(dnsServers = setOf(scopedDns))

        assertTrue(policy.allows(address("fe80::53"), 53, 7))
        assertFalse(policy.allows(address("fe80::53"), 53, 8))
        assertFalse(policy.allows(address("2606:4700:4700::1111"), 443, 7))
    }

    @Test
    fun protocolDecodesStrictCreateAndAuthorizationRecords() {
        val create = AndeeNetworkProtocol.decodeRequest(
            request(1, intArrayOf(2, 1, 6)),
            28,
            0,
        ) as AndeeNetworkRequest.CreateSocket
        assertEquals(1L, create.id)
        assertEquals(2, create.family)
        assertEquals(1, create.type)
        assertEquals(6, create.protocol)

        val destination = address("1.1.1.1")
        val authorizationPayload = ByteBuffer.allocate(16)
            .order(ByteOrder.BIG_ENDIAN)
            .putShort(2.toShort())
            .put(1.toByte())
            .put(0.toByte())
            .putShort(443.toShort())
            .putShort(destination.size.toShort())
            .putInt(0)
            .put(destination)
            .array()
        val authorizationRecord = record(2, 2, authorizationPayload)
        val authorization = AndeeNetworkProtocol.decodeRequest(
            authorizationRecord,
            authorizationRecord.size,
            create.id,
        ) as AndeeNetworkRequest.AuthorizeDestination
        assertEquals(443, authorization.port)
        assertArrayEquals(destination, authorization.address)
    }

    @Test
    fun protocolRejectsDuplicateIdsFlagsAndExtraBytes() {
        val create = request(4, intArrayOf(2, 1, 6))
        assertThrows(IllegalArgumentException::class.java) {
            AndeeNetworkProtocol.decodeRequest(create, create.size, 4)
        }
        create[7] = 1
        assertThrows(IllegalArgumentException::class.java) {
            AndeeNetworkProtocol.decodeRequest(create, create.size, 0)
        }
        val oversized = request(5, intArrayOf(2, 1, 6)).copyOf(29)
        assertThrows(IllegalArgumentException::class.java) {
            AndeeNetworkProtocol.decodeRequest(oversized, oversized.size, 0)
        }
    }

    private fun policy(
        dnsServers: Set<AndeeIpAddress> = emptySet(),
        localAddresses: Set<AndeeIpAddress> = emptySet(),
        localPrefixes: Set<AndeeIpPrefix> = emptySet(),
    ) = AndeeNetworkPolicy(dnsServers, localAddresses, localPrefixes)

    private fun ip(value: String, scopeId: Int = 0) =
        AndeeIpAddress(address(value).toList(), scopeId)

    private fun prefix(value: String) = AndeeIpPrefix.parse(value)

    private fun address(value: String): ByteArray = InetAddress.getByName(value).address

    private fun mapped(value: String): ByteArray =
        ByteArray(16).also { mapped ->
            mapped[10] = 0xff.toByte()
            mapped[11] = 0xff.toByte()
            address(value).copyInto(mapped, 12)
        }

    private fun request(id: Int, payload: IntArray): ByteArray = record(
        id,
        1,
        ByteBuffer.allocate(payload.size * Int.SIZE_BYTES)
            .order(ByteOrder.BIG_ENDIAN)
            .also { buffer -> payload.forEach(buffer::putInt) }
            .array(),
    )

    private fun record(id: Int, opcode: Int, payload: ByteArray): ByteArray =
        ByteBuffer.allocate(16 + payload.size)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(0x414e4431)
            .put(1.toByte())
            .put(opcode.toByte())
            .putShort(0.toShort())
            .putInt(id)
            .putInt(payload.size)
            .put(payload)
            .array()
}
