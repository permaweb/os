package org.permaweb.andee

import android.os.Binder
import android.os.Process
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Creates native Internet sockets in the main UID for one isolated command. */
internal class AndeeNetworkBroker(
    private val policy: AndeeNetworkPolicy,
) : IAndeeNetworkBroker.Stub(), AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val isolatedUid = AtomicInteger(UNBOUND_UID)

    override fun createSocket(family: Int, type: Int, protocol: Int): AndeeSocketResult {
        checkCaller()?.let { return AndeeSocketResult(it, null) }
        val baseType = type and SOCKET_FLAGS.inv()
        if (family != OsConstants.AF_INET && family != OsConstants.AF_INET6) {
            return AndeeSocketResult(OsConstants.EAFNOSUPPORT, null)
        }
        val expectedProtocol = when (baseType) {
            OsConstants.SOCK_STREAM -> OsConstants.IPPROTO_TCP
            OsConstants.SOCK_DGRAM -> OsConstants.IPPROTO_UDP
            else -> return AndeeSocketResult(OsConstants.EPROTONOSUPPORT, null)
        }
        if (protocol != 0 && protocol != expectedProtocol) {
            return AndeeSocketResult(OsConstants.EPROTONOSUPPORT, null)
        }
        val socket = try {
            Os.socket(family, type or OsConstants.SOCK_CLOEXEC, protocol)
        } catch (failure: ErrnoException) {
            return AndeeSocketResult(failure.errno, null)
        }
        return try {
            AndeeSocketResult(0, android.os.ParcelFileDescriptor.dup(socket))
        } finally {
            runCatching { Os.close(socket) }
        }
    }

    override fun authorizeDestination(
        family: Int,
        transport: Int,
        port: Int,
        scopeId: Int,
        address: ByteArray,
    ): Int {
        checkCaller()?.let { return it }
        val expectedAddressBytes = when (family) {
            OsConstants.AF_INET -> IPV4_BYTES
            OsConstants.AF_INET6 -> IPV6_BYTES
            else -> return OsConstants.EAFNOSUPPORT
        }
        if (address.size != expectedAddressBytes || scopeId < 0) return OsConstants.EINVAL
        if (transport != OsConstants.SOCK_STREAM && transport != OsConstants.SOCK_DGRAM) {
            return OsConstants.EPROTONOSUPPORT
        }
        return if (policy.allows(address, port, scopeId)) 0 else OsConstants.EACCES
    }

    override fun close() {
        closed.set(true)
    }

    private fun checkCaller(): Int? {
        if (closed.get()) return OsConstants.EBADF
        val caller = Binder.getCallingUid()
        // This Binder object is an unforgeable per-command capability passed
        // only to the manifest-declared isolated service. Pin its first remote
        // caller without depending on Process.isIsolatedUid(), which was not a
        // public API before Android 14.
        if (caller == Process.myUid()) {
            return OsConstants.EACCES
        }
        val bound = isolatedUid.get()
        if (bound == UNBOUND_UID) {
            if (!isolatedUid.compareAndSet(UNBOUND_UID, caller)) return checkCaller()
        } else if (bound != caller) {
            return OsConstants.EACCES
        }
        return if (closed.get()) OsConstants.EBADF else null
    }

    private companion object {
        const val UNBOUND_UID = -1
        const val IPV4_BYTES = 4
        const val IPV6_BYTES = 16
        val SOCKET_FLAGS = OsConstants.SOCK_CLOEXEC or OsConstants.SOCK_NONBLOCK
    }
}
