package org.permaweb.andee

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.RemoteException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import java.io.FileDescriptor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** Serves the isolated syscall adapter over a per-command capability socket. */
internal class AndeeNetworkCapabilityServer(
    private val listener: LocalServerSocket,
    private val broker: IAndeeNetworkBroker,
    private val guestProcess: java.lang.Process,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val accepted = AtomicBoolean(false)
    private val connected = CountDownLatch(1)
    private val failure = AtomicReference<Throwable?>()
    private val client = AtomicReference<LocalSocket?>()
    private val serverThread = thread(start = false, name = "AndockNetworkCapability") {
        runCatching(::acceptAndServe).onFailure {
            if (!closed.get()) failure.compareAndSet(null, it)
        }
        connected.countDown()
    }

    fun start() {
        serverThread.start()
    }

    fun awaitConnected() {
        check(connected.await(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            "Andock syscall adapter did not request its network capability"
        }
        failure.get()?.let { throw it }
        check(accepted.get()) {
            if (guestProcess.isAlive) {
                "Andock syscall adapter did not request its network capability"
            } else {
                "Andock guest exited before requesting its network capability"
            }
        }
    }

    fun throwIfFailed() {
        failure.get()?.let { throw it }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { client.getAndSet(null)?.close() }
        runCatching { listener.close() }
        connected.countDown()
        if (serverThread.isAlive) serverThread.join(CLOSE_TIMEOUT_MS)
    }

    private fun acceptAndServe() {
        val poll = StructPollfd().apply {
            fd = listener.fileDescriptor
            events = OsConstants.POLLIN.toShort()
        }
        val ready = Os.poll(arrayOf(poll), CONNECT_TIMEOUT_MS.toInt())
        check(ready > 0 && poll.revents.toInt() and OsConstants.POLLIN != 0) {
            if (guestProcess.isAlive) {
                "Andock syscall adapter did not connect to its network capability"
            } else {
                "Andock guest exited before connecting to its network capability"
            }
        }
        listener.accept().use { accepted ->
            require(accepted.peerCredentials.uid == Process.myUid()) {
                "Andock network capability requested by an unexpected UID"
            }
            this.accepted.set(true)
            client.set(accepted)
            connected.countDown()
            serve(accepted)
            client.compareAndSet(accepted, null)
        }
    }

    private fun serve(socket: LocalSocket) {
        val packet = ByteArray(AndeeNetworkProtocol.MAX_PACKET_BYTES + 1)
        var lastRequestId = 0L
        while (!closed.get()) {
            val packetBytes = socket.inputStream.read(packet)
            if (packetBytes < 0) return
            val receivedDescriptors = socket.ancillaryFileDescriptors.orEmpty()
            receivedDescriptors.forEach { descriptor -> runCatching { Os.close(descriptor) } }
            require(receivedDescriptors.isEmpty()) { "network requests cannot carry descriptors" }
            val request = AndeeNetworkProtocol.decodeRequest(packet, packetBytes, lastRequestId)
            lastRequestId = request.id
            when (request) {
                is AndeeNetworkRequest.CreateSocket -> serveCreate(socket, request)
                is AndeeNetworkRequest.AuthorizeDestination -> serveAuthorization(socket, request)
            }
        }
        packet.fill(0)
    }

    private fun serveCreate(socket: LocalSocket, request: AndeeNetworkRequest.CreateSocket) {
        var descriptor: ParcelFileDescriptor? = null
        val errno = try {
            val result = broker.createSocket(request.family, request.type, request.protocol)
            descriptor = result.descriptor
            result.errno
        } catch (_: RemoteException) {
            OsConstants.EIO
        }
        descriptor.use {
            sendResponse(socket, request, errno, it?.fileDescriptor)
        }
    }

    private fun serveAuthorization(
        socket: LocalSocket,
        request: AndeeNetworkRequest.AuthorizeDestination,
    ) {
        val errno = try {
            broker.authorizeDestination(
                request.family,
                request.transport,
                request.port,
                request.scopeId,
                request.address,
            )
        } catch (_: RemoteException) {
            OsConstants.EIO
        }
        sendResponse(socket, request, errno, null)
    }

    private fun sendResponse(
        socket: LocalSocket,
        request: AndeeNetworkRequest,
        errno: Int,
        descriptor: FileDescriptor?,
    ) {
        require(errno >= 0) { "network broker returned a negative errno" }
        require(descriptor == null || request is AndeeNetworkRequest.CreateSocket && errno == 0) {
            "only successful socket creation can return a descriptor"
        }
        try {
            socket.setFileDescriptorsForSend(descriptor?.let { arrayOf(it) })
            socket.outputStream.write(AndeeNetworkProtocol.encodeResponse(request, errno))
            socket.outputStream.flush()
        } finally {
            socket.setFileDescriptorsForSend(null)
        }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000L
        const val CLOSE_TIMEOUT_MS = 1_000L
    }
}

internal sealed class AndeeNetworkRequest(
    open val id: Long,
    val opcode: Int,
) {
    data class CreateSocket(
        override val id: Long,
        val family: Int,
        val type: Int,
        val protocol: Int,
    ) : AndeeNetworkRequest(id, AndeeNetworkProtocol.OP_CREATE_SOCKET)

    data class AuthorizeDestination(
        override val id: Long,
        val family: Int,
        val transport: Int,
        val port: Int,
        val scopeId: Int,
        val address: ByteArray,
    ) : AndeeNetworkRequest(id, AndeeNetworkProtocol.OP_AUTHORIZE_DESTINATION)
}

/**
 * One big-endian SOCK_SEQPACKET record per request and response.
 *
 * Header: magic u32, version u8, opcode u8, flags u16, request-id u32,
 * payload-length u32. Responses set bit 7 of the opcode and contain one errno i32.
 */
internal object AndeeNetworkProtocol {
    const val MAX_PACKET_BYTES = 64
    const val OP_CREATE_SOCKET = 1
    const val OP_AUTHORIZE_DESTINATION = 2

    private const val MAGIC = 0x414e4431
    private const val VERSION = 1
    private const val RESPONSE_BIT = 0x80
    private const val HEADER_BYTES = 16
    private const val CREATE_PAYLOAD_BYTES = 12
    private const val AUTHORIZE_FIXED_BYTES = 12
    private const val RESPONSE_PAYLOAD_BYTES = 4

    fun decodeRequest(packet: ByteArray, packetBytes: Int, lastRequestId: Long): AndeeNetworkRequest {
        require(packetBytes in HEADER_BYTES..MAX_PACKET_BYTES) { "invalid network request length" }
        val bytes = ByteBuffer.wrap(packet, 0, packetBytes).order(ByteOrder.BIG_ENDIAN)
        require(bytes.int == MAGIC) { "invalid network request magic" }
        require(bytes.get().toInt() and 0xff == VERSION) { "unsupported network protocol" }
        val opcode = bytes.get().toInt() and 0xff
        require(opcode and RESPONSE_BIT == 0) { "network request used a response opcode" }
        require(bytes.short.toInt() and 0xffff == 0) { "network request flags must be zero" }
        val requestId = bytes.int.toLong() and 0xffff_ffffL
        require(requestId > lastRequestId) { "network request IDs must increase" }
        val payloadBytes = bytes.int
        require(payloadBytes >= 0 && payloadBytes == packetBytes - HEADER_BYTES) {
            "network request payload length does not match its record"
        }
        return when (opcode) {
            OP_CREATE_SOCKET -> {
                require(payloadBytes == CREATE_PAYLOAD_BYTES) { "invalid socket request length" }
                AndeeNetworkRequest.CreateSocket(requestId, bytes.int, bytes.int, bytes.int)
            }
            OP_AUTHORIZE_DESTINATION -> decodeAuthorization(requestId, bytes, payloadBytes)
            else -> error("unsupported network request opcode")
        }.also { require(!bytes.hasRemaining()) { "network request has trailing bytes" } }
    }

    fun encodeResponse(request: AndeeNetworkRequest, errno: Int): ByteArray =
        ByteBuffer.allocate(HEADER_BYTES + RESPONSE_PAYLOAD_BYTES)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(MAGIC)
            .put(VERSION.toByte())
            .put((request.opcode or RESPONSE_BIT).toByte())
            .putShort(0)
            .putInt(request.id.toInt())
            .putInt(RESPONSE_PAYLOAD_BYTES)
            .putInt(errno)
            .array()

    private fun decodeAuthorization(
        requestId: Long,
        bytes: ByteBuffer,
        payloadBytes: Int,
    ): AndeeNetworkRequest.AuthorizeDestination {
        require(payloadBytes >= AUTHORIZE_FIXED_BYTES) { "invalid authorization request length" }
        val family = bytes.short.toInt() and 0xffff
        val transport = bytes.get().toInt() and 0xff
        require(bytes.get().toInt() == 0) { "authorization reserved byte must be zero" }
        val port = bytes.short.toInt() and 0xffff
        val addressBytes = bytes.short.toInt() and 0xffff
        val unsignedScopeId = bytes.int.toLong() and 0xffff_ffffL
        require(unsignedScopeId <= Int.MAX_VALUE) { "invalid authorization scope ID" }
        require(addressBytes == IPV4_BYTES || addressBytes == IPV6_BYTES) {
            "invalid authorization address length"
        }
        require(payloadBytes == AUTHORIZE_FIXED_BYTES + addressBytes) {
            "authorization address length does not match its record"
        }
        return AndeeNetworkRequest.AuthorizeDestination(
            requestId,
            family,
            transport,
            port,
            unsignedScopeId.toInt(),
            ByteArray(addressBytes).also(bytes::get),
        )
    }

    private const val IPV4_BYTES = 4
    private const val IPV6_BYTES = 16
}
