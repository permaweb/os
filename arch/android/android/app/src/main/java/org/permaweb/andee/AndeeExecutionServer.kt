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

/** Framed app-private transport between HyperBEAM and the Andock manager. */
internal class AndeeExecutionServer(
    private val context: Context,
    private val dispatch: (JSONObject) -> JSONObject,
    private val failureResponse: (Throwable) -> JSONObject,
) : AutoCloseable {
    @Volatile private var running = false
    private var thread: Thread? = null
    private var listenerSocket: LocalSocket? = null
    private var serverSocket: LocalServerSocket? = null

    fun start() {
        check(!running) { "execution server is already running" }
        require(AndeePaths.runDir(context).mkdirs() || AndeePaths.runDir(context).isDirectory)
        running = true
        thread = Thread(::serve, "AndeeExecutionServer").also { it.start() }
    }

    override fun close() {
        running = false
        runCatching { serverSocket?.close() }
        runCatching { listenerSocket?.close() }
        AndeePaths.executionSocketFile(context).delete()
        thread?.interrupt()
        thread = null
    }

    private fun serve() {
        val socketFile = AndeePaths.executionSocketFile(context)
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
            Log.i(TAG, "execution service listening at ${socketFile.absolutePath}")
            while (running) {
                val client = try {
                    server.accept()
                } catch (failure: Exception) {
                    if (running) Log.w(TAG, "execution accept failed", failure)
                    break
                }
                Thread({ handle(client) }, "AndeeExecutionRequest").start()
            }
        } finally {
            serverSocket = null
            listenerSocket = null
            socketFile.delete()
        }
    }

    private fun handle(socket: LocalSocket) {
        try {
            require(socket.peerCredentials.uid == Process.myUid()) {
                "execution request came from an unexpected UID"
            }
            val input = DataInputStream(socket.inputStream)
            val output = DataOutputStream(socket.outputStream)
            val length = input.readInt()
            val response = if (length !in 1..AndeeExecutionPolicy.MAX_REQUEST_BYTES) {
                failureResponse(ExecutionFailure(413, "invalid-request-frame"))
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
            val bytes = response.toString().toByteArray(Charsets.UTF_8)
            try {
                require(bytes.size <= AndeeExecutionPolicy.MAX_REQUEST_BYTES) {
                    "execution response is too large"
                }
                output.writeInt(bytes.size)
                output.write(bytes)
                output.flush()
            } finally {
                bytes.fill(0)
            }
        } catch (failure: Exception) {
            if (running) Log.w(TAG, "execution request failed", failure)
        } finally {
            runCatching { socket.close() }
        }
    }

    private companion object {
        const val TAG = "AndeeExecution"
    }
}
