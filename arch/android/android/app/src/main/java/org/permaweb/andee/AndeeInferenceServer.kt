package org.permaweb.andee

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.util.Log
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/** Framed app-private transport between HyperBEAM and LiteRT-LM. */
internal class AndeeInferenceServer(
    private val context: Context,
    private val dispatch: (JSONObject) -> JSONObject,
    private val failureResponse: (Throwable) -> JSONObject,
) : AutoCloseable {
    @Volatile private var running = false
    private var thread: Thread? = null
    private var listenerSocket: LocalSocket? = null
    private var serverSocket: LocalServerSocket? = null
    private val ready = CountDownLatch(1)
    private val requestSlots = Semaphore(AndeeInferencePolicy.MAX_CONCURRENT_REQUESTS, true)
    private val clients = ConcurrentHashMap.newKeySet<LocalSocket>()
    @Volatile private var startupFailure: Throwable? = null

    fun start() {
        check(!running) { "inference server is already running" }
        require(AndeePaths.runDir(context).mkdirs() || AndeePaths.runDir(context).isDirectory)
        running = true
        thread = Thread(::serve, "AndeeInferenceServer").also { it.start() }
        if (!ready.await(10, TimeUnit.SECONDS)) {
            close()
            throw IllegalStateException("inference service socket did not become ready")
        }
        startupFailure?.let {
            close()
            throw IllegalStateException("inference service socket failed", it)
        }
    }

    override fun close() {
        running = false
        runCatching { serverSocket?.close() }
        runCatching { listenerSocket?.close() }
        clients.forEach { client -> runCatching { client.close() } }
        AndeePaths.inferenceSocketFile(context).delete()
        thread?.interrupt()
        thread = null
    }

    private fun serve() {
        val socketFile = AndeePaths.inferenceSocketFile(context)
        try {
            socketFile.delete()
            val listener = LocalSocket()
            listener.bind(
                LocalSocketAddress(
                    socketFile.absolutePath,
                    LocalSocketAddress.Namespace.FILESYSTEM,
                ),
            )
            listenerSocket = listener
            val server = LocalServerSocket(listener.fileDescriptor)
            serverSocket = server
            ready.countDown()
            Log.i(TAG, "inference service listening at ${socketFile.absolutePath}")
            while (running) {
                val client = try {
                    server.accept()
                } catch (failure: Exception) {
                    if (running) Log.w(TAG, "inference accept failed", failure)
                    break
                }
                if (!running) {
                    runCatching { client.close() }
                    break
                }
                clients.add(client)
                if (!requestSlots.tryAcquire()) {
                    respond(client, failureResponse(InferenceFailure(429, "inference-server-busy")))
                    clients.remove(client)
                    continue
                }
                Thread(
                    {
                        try {
                            handle(client)
                        } finally {
                            clients.remove(client)
                            requestSlots.release()
                        }
                    },
                    "AndeeInferenceRequest",
                ).start()
            }
        } catch (failure: Throwable) {
            startupFailure = failure
            if (running) Log.e(TAG, "inference service failed", failure)
        } finally {
            ready.countDown()
            serverSocket = null
            listenerSocket = null
            socketFile.delete()
        }
    }

    private fun handle(socket: LocalSocket) {
        try {
            socket.soTimeout = AndeeInferencePolicy.SOCKET_TIMEOUT_MILLIS
            require(socket.peerCredentials.uid == Process.myUid()) {
                "inference request came from an unexpected UID"
            }
            val input = DataInputStream(socket.inputStream)
            val length = input.readInt()
            val response = if (length !in 1..AndeeInferencePolicy.MAX_FRAME_BYTES) {
                failureResponse(InferenceFailure(413, "invalid-request-frame"))
            } else {
                val payload = ByteArray(length)
                try {
                    input.readFully(payload)
                    runCatching {
                        dispatch(JSONObject(String(payload, Charsets.UTF_8)))
                    }.getOrElse(failureResponse)
                } finally {
                    payload.fill(0)
                }
            }
            respond(socket, response)
        } catch (failure: Exception) {
            if (running) Log.w(TAG, "inference request failed", failure)
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun respond(socket: LocalSocket, response: JSONObject) {
        try {
            val bytes = response.toString().toByteArray(Charsets.UTF_8)
            try {
                require(bytes.size <= AndeeInferencePolicy.MAX_FRAME_BYTES) {
                    "inference response is too large"
                }
                DataOutputStream(socket.outputStream).use { output ->
                    output.writeInt(bytes.size)
                    output.write(bytes)
                    output.flush()
                }
            } finally {
                bytes.fill(0)
            }
        } catch (failure: Exception) {
            if (running) Log.w(TAG, "inference response failed", failure)
        } finally {
            runCatching { socket.close() }
        }
    }

    private companion object {
        const val TAG = "AndeeInference"
    }
}
