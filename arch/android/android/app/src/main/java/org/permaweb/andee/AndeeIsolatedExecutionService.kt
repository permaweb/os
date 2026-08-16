package org.permaweb.andee

import android.app.Service
import android.content.Intent
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** Executes PRoot and every guest child under one Android isolated UID. */
class AndeeIsolatedExecutionService : Service() {
    @Volatile private var active: java.lang.Process? = null

    private val binder = object : IAndeeExecutionWorker.Stub() {
        override fun execute(
            command: String,
            cwd: String,
            timeoutMs: Long,
            mergeError: Boolean,
            image: ParcelFileDescriptor,
            input: ParcelFileDescriptor?,
            output: ParcelFileDescriptor,
            networkBroker: IAndeeNetworkBroker?,
            resolverConfiguration: String?,
        ): String = runCommand(
            command,
            cwd,
            timeoutMs.coerceAtLeast(1),
            mergeError,
            image,
            input,
            output,
            networkBroker,
            resolverConfiguration,
        ).toString()

        override fun stop() {
            stopActive()
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        stopActive()
        super.onDestroy()
    }

    private fun runCommand(
        command: String,
        cwd: String,
        timeoutMs: Long,
        mergeError: Boolean,
        image: ParcelFileDescriptor,
        input: ParcelFileDescriptor?,
        output: ParcelFileDescriptor,
        networkBroker: IAndeeNetworkBroker?,
        resolverConfiguration: String?,
    ): JSONObject {
        require((networkBroker == null) == (resolverConfiguration == null)) {
            "network broker and resolver configuration must be provided together"
        }
        resolverConfiguration?.let {
            require(it.toByteArray(Charsets.UTF_8).size <= MAX_RESOLVER_BYTES) {
                "resolver configuration is too large"
            }
            require(it.isNotEmpty()) { "resolver configuration cannot be empty" }
        }
        val nativeRoot = applicationInfo.nativeLibraryDir
        val launcher = File(nativeRoot, PROOT_LAUNCHER)
        val proot = File(nativeRoot, PROOT_EXECUTABLE)
        val loader = File(nativeRoot, PROOT_LOADER)
        require(launcher.isFile && launcher.canExecute()) {
            "missing packaged Andock launcher"
        }
        require(proot.isFile && proot.canExecute()) {
            "missing packaged PRoot executable"
        }
        require(loader.isFile && loader.canExecute()) { "missing packaged PRoot loader" }

        val capabilityName = capabilityName("image")
        val capabilityListener = LocalSocket(LocalSocket.SOCKET_SEQPACKET).apply {
            bind(LocalSocketAddress(capabilityName, LocalSocketAddress.Namespace.ABSTRACT))
        }
        val capabilitySocket = LocalServerSocket(capabilityListener.fileDescriptor)
        val networkCapabilityName = networkBroker?.let { capabilityName("network") }
        val networkCapabilityListener = networkCapabilityName?.let { name ->
            LocalSocket(LocalSocket.SOCKET_SEQPACKET).apply {
                bind(LocalSocketAddress(name, LocalSocketAddress.Namespace.ABSTRACT))
            }
        }
        val networkCapabilitySocket = networkCapabilityListener?.let {
            LocalServerSocket(it.fileDescriptor)
        }
        var process: java.lang.Process? = null
        var networkServer: AndeeNetworkCapabilityServer? = null
        val errors = ByteArrayOutputStream()
        try {
            process = synchronized(this) {
                check(active?.isAlive != true) { "isolated worker already has an active command" }
                val arguments = mutableListOf(
                    launcher.absolutePath,
                    "--socket",
                    capabilityName,
                )
                networkCapabilityName?.let {
                    arguments += listOf("--network-socket", it)
                }
                arguments += listOf(
                    "--",
                    proot.absolutePath,
                    "--kill-on-exit",
                    "-0",
                    "-r",
                    "/system",
                    "-w",
                    "/",
                    "/usr/bin/env",
                    "-C",
                    cwd,
                    "/bin/bash",
                )
                if (networkBroker == null) {
                    arguments += listOf("-lc", command)
                } else {
                    arguments += listOf("-c", NETWORK_COMMAND, "andock-network-init", command)
                }
                ProcessBuilder(arguments)
                    .redirectErrorStream(mergeError)
                    .also { builder ->
                        builder.environment()["PROOT_LOADER"] = loader.absolutePath
                        builder.environment()["PROOT_F2FS_WORKAROUND"] = "0"
                        builder.environment()["LD_LIBRARY_PATH"] = nativeRoot
                        builder.environment()["PATH"] =
                            "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                        builder.environment()["HOME"] = "/root"
                        builder.environment()["USER"] = "root"
                        builder.environment()["LOGNAME"] = "root"
                        builder.environment()["SHELL"] = "/bin/bash"
                        builder.environment()["TMPDIR"] = "/tmp"
                        builder.environment()["LANG"] = "C.UTF-8"
                        builder.environment()["DEBIAN_FRONTEND"] = "noninteractive"
                        builder.environment()["PIP_BREAK_SYSTEM_PACKAGES"] = "1"
                        resolverConfiguration?.let {
                            builder.environment()["ANDOCK_RESOLV_CONF"] = it
                        }
                    }
                    .start()
                    .also { active = it }
            }
            if (networkBroker != null && networkCapabilitySocket != null) {
                networkServer = AndeeNetworkCapabilityServer(
                    networkCapabilitySocket,
                    networkBroker,
                    process,
                ).also(AndeeNetworkCapabilityServer::start)
            }
            sendImageCapability(capabilitySocket, image, process)
            networkServer?.awaitConnected()
        } catch (failure: Throwable) {
            process?.let(::terminateGuestProcesses)
            networkServer?.close()
            networkCapabilityListener?.close()
            throw failure
        } finally {
            capabilitySocket.close()
            capabilityListener.close()
            image.close()
        }

        val streamFailure = AtomicReference<Throwable?>()
        val stdin = thread(name = "AndockInput") {
            runCatching {
                process.outputStream.use { destination ->
                    input?.let {
                        ParcelFileDescriptor.AutoCloseInputStream(it).use { source ->
                            source.copyTo(destination)
                        }
                    }
                }
            }.onFailure { streamFailure.compareAndSet(null, it) }
        }
        val stdout = thread(name = "AndockOutput") {
            runCatching {
                ParcelFileDescriptor.AutoCloseOutputStream(output).use { destination ->
                    process.inputStream.use { source -> source.copyTo(destination) }
                }
            }.onFailure { streamFailure.compareAndSet(null, it) }
        }
        val stderr = if (mergeError) null else thread(name = "AndockError") {
            runCatching {
                process.errorStream.use { source ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        if (errors.size() < AndeeExecutionPolicy.MAX_ERROR_BYTES) {
                            errors.write(
                                buffer,
                                0,
                                minOf(
                                    read,
                                    AndeeExecutionPolicy.MAX_ERROR_BYTES - errors.size(),
                                ),
                            )
                        }
                    }
                    buffer.fill(0)
                }
            }.onFailure { streamFailure.compareAndSet(null, it) }
        }

        try {
            val completed = process.waitFor(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            if (!completed) terminateGuestProcesses(process)
            stdin.join()
            stdout.join()
            stderr?.join()
            if (completed) streamFailure.get()?.let { throw it }
            if (completed) networkServer?.throwIfFailed()
            return JSONObject()
                .put("exit-code", if (completed) process.exitValue() else 124)
                .put("timed-out", !completed)
                .put("error", encode(errors.toByteArray()))
        } finally {
            synchronized(this) {
                if (active === process) active = null
            }
            signalOtherUidProcesses(OsConstants.SIGKILL)
            networkServer?.close()
            networkCapabilityListener?.close()
            input?.close()
            output.close()
        }
    }

    @Synchronized
    private fun stopActive() {
        val process = active ?: return
        active = null
        if (process.isAlive) terminateGuestProcesses(process)
    }

    private fun terminateGuestProcesses(process: java.lang.Process) {
        process.destroy()
        signalOtherUidProcesses(OsConstants.SIGTERM)
        process.waitFor(500, TimeUnit.MILLISECONDS)
        signalOtherUidProcesses(OsConstants.SIGKILL)
        process.waitFor(500, TimeUnit.MILLISECONDS)
    }

    private fun signalOtherUidProcesses(signal: Int) {
        val ownPid = Process.myPid()
        val ownUid = Process.myUid()
        File("/proc").listFiles().orEmpty().forEach { entry ->
            val pid = entry.name.toIntOrNull() ?: return@forEach
            if (pid == ownPid) return@forEach
            val uid = runCatching { Os.stat(entry.absolutePath).st_uid }.getOrNull()
            if (uid == ownUid) runCatching { Os.kill(pid, signal) }
        }
    }

    private fun sendImageCapability(
        listener: LocalServerSocket,
        image: ParcelFileDescriptor,
        process: java.lang.Process,
    ) {
        val poll = StructPollfd().apply {
            fd = listener.fileDescriptor
            events = OsConstants.POLLIN.toShort()
        }
        val ready = Os.poll(arrayOf(poll), CAPABILITY_TIMEOUT_MS)
        check(ready > 0 && poll.revents.toInt() and OsConstants.POLLIN != 0) {
            if (process.isAlive) {
                "Andock launcher did not request its image capability"
            } else {
                "Andock launcher exited before requesting its image capability"
            }
        }
        listener.accept().use { client ->
            require(client.peerCredentials.uid == Process.myUid()) {
                "Andock image capability requested by an unexpected UID"
            }
            client.setFileDescriptorsForSend(arrayOf(image.fileDescriptor))
            client.outputStream.write(IMAGE_CAPABILITY_BYTE)
            client.outputStream.flush()
            client.setFileDescriptorsForSend(null)
        }
    }

    private fun capabilityName(kind: String): String {
        val nonce = ByteArray(18)
        SecureRandom().nextBytes(nonce)
        return "andock.$kind.${encode(nonce)}"
    }

    private fun encode(value: ByteArray): String = Base64.encodeToString(
        value,
        Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
    )

    private companion object {
        const val PROOT_LAUNCHER = "libandee_andock_launcher.so"
        const val PROOT_EXECUTABLE = "libandee_proot.so"
        const val PROOT_LOADER = "libandee_proot_loader.so"
        const val CAPABILITY_TIMEOUT_MS = 10_000
        const val IMAGE_CAPABILITY_BYTE = 0x41
        const val MAX_RESOLVER_BYTES = 4 * 1024
        const val NETWORK_COMMAND =
            "umask 022; printf '%s' \"\$ANDOCK_RESOLV_CONF\" > /etc/resolv.conf || exit 125; " +
                "unset ANDOCK_RESOLV_CONF; exec /bin/bash -lc \"\$1\""
    }
}
