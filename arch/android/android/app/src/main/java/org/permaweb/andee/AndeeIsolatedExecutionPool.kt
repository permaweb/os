package org.permaweb.andee

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Base64
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Allocates one Android isolated-process instance per active member. */
internal class AndeeIsolatedExecutionPool(
    private val context: Context,
) : AutoCloseable {
    private val workers = ConcurrentHashMap<String, WorkerHandle>()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private val poolLock = Any()

    fun execute(
        memberId: String,
        command: String,
        cwd: String,
        timeoutMs: Int,
        mergeError: Boolean,
        image: ParcelFileDescriptor,
        input: ParcelFileDescriptor?,
        output: ParcelFileDescriptor,
    ): JSONObject {
        var worker: WorkerHandle? = null
        return try {
            cancelled.remove(memberId)
            worker = synchronized(poolLock) {
                if (cancelled.remove(memberId)) throw ExecutionCancelledException()
                workers[memberId]
                    ?.takeUnless(WorkerHandle::isDisconnected)
                    ?: replaceWorker(memberId)
            }.also { it.active = true }
            worker.awaitConnected()
            val response = worker.service().execute(
                command,
                cwd,
                timeoutMs,
                mergeError,
                image,
                input,
                output,
            )
            JSONObject(response).also {
                if (it.optBoolean("timed-out")) stopWorker(memberId)
            }
        } catch (failure: Throwable) {
            val explicitlyCancelled =
                failure is ExecutionCancelledException || cancelled.remove(memberId)
            stopWorker(memberId)
            if (explicitlyCancelled) {
                JSONObject()
                    .put("exit-code", 130)
                    .put("timed-out", false)
                    .put("cancelled", true)
                    .put("error", "")
            } else {
                throw failure
            }
        } finally {
            worker?.let {
                it.active = false
                it.lastUsedNanos = System.nanoTime()
            }
        }
    }

    fun stop(memberId: String) {
        cancelled.add(memberId)
        stopWorker(memberId)
    }

    override fun close() {
        synchronized(poolLock) { workers.keys.toList() }.forEach(::stopWorker)
        cancelled.clear()
    }

    private fun bind(memberId: String): WorkerHandle {
        if (workers.size >= AndeeExecutionPolicy.MAX_ACTIVE_MEMBERS) {
            val idle = workers.entries
                .filter { !it.value.active }
                .minByOrNull { it.value.lastUsedNanos }
                ?: throw ExecutionFailure(429, "isolated-execution-capacity-reached")
            stopWorker(idle.key)
        }
        val handle = WorkerHandle()
        val accepted = context.bindIsolatedService(
            Intent(context, AndeeIsolatedExecutionService::class.java),
            Context.BIND_AUTO_CREATE,
            "member${memberToken(memberId)}",
            context.mainExecutor,
            handle.connection,
        )
        check(accepted) { "isolated execution worker binding was rejected" }
        return handle
    }

    private fun replaceWorker(memberId: String): WorkerHandle {
        stopWorker(memberId)
        return bind(memberId).also { workers[memberId] = it }
    }

    private fun stopWorker(memberId: String) {
        val worker = synchronized(poolLock) { workers.remove(memberId) } ?: return
        runCatching { worker.serviceOrNull()?.stop() }
        worker.disconnect()
        runCatching { context.unbindService(worker.connection) }
    }

    private fun memberToken(memberId: String): String =
        Base64.encodeToString(
            MessageDigest.getInstance("SHA-256").digest(memberId.toByteArray()),
            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
        ).filter(Char::isLetterOrDigit).take(32)

    private class WorkerHandle {
        val connected = CountDownLatch(1)
        @Volatile var active = false
        @Volatile var lastUsedNanos = System.nanoTime()
        @Volatile private var remote: IAndeeExecutionWorker? = null
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                remote = IAndeeExecutionWorker.Stub.asInterface(binder)
                connected.countDown()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                remote = null
                connected.countDown()
            }

            override fun onBindingDied(name: ComponentName?) {
                remote = null
                connected.countDown()
            }

            override fun onNullBinding(name: ComponentName?) {
                remote = null
                connected.countDown()
            }
        }

        fun service(): IAndeeExecutionWorker =
            serviceOrNull() ?: error("isolated execution worker unavailable")

        fun serviceOrNull(): IAndeeExecutionWorker? = remote

        fun disconnect() {
            remote = null
            connected.countDown()
        }

        fun isDisconnected(): Boolean = connected.count == 0L && remote == null

        fun awaitConnected() {
            check(connected.await(BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                "isolated execution worker binding timed out"
            }
            check(remote != null) { "isolated execution worker unavailable" }
        }
    }

    private companion object {
        const val BIND_TIMEOUT_MS = 10_000L
    }

    private class ExecutionCancelledException : RuntimeException()
}
