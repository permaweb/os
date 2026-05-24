package org.permaweb.andee

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

class AndeeService : Service() {
    private var cryptoAgent: AndeeCryptoAgent? = null
    private var hyperbeamRuntime: HyperbeamRuntime? = null
    private var starterThread: Thread? = null
    @Volatile private var stopping = false

    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIFICATION_ID, notification(), foregroundType())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TERMINATE -> {
                terminateProcess(startId)
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                stopping = true
                stopRuntime()
                stopForegroundCompat()
                stopSelfResult(startId)
                return START_NOT_STICKY
            }
        }
        if (stopping) {
            stopping = true
            stopRuntime()
            stopForegroundCompat()
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        stopping = false
        startRuntimeIfNeeded()
        return START_STICKY
    }

    private fun startRuntimeIfNeeded() {
        if (hyperbeamRuntime?.isAlive() == true || starterThread?.isAlive == true) return
        Thread {
            var agent: AndeeCryptoAgent? = null
            var runtime: HyperbeamRuntime? = null
            try {
                val runtimeRoot = RuntimeExtractor(this).extractIfNeeded()
                val currentAgent = AndeeCryptoAgent(this).also { it.start() }
                agent = currentAgent
                if (stopping) {
                    currentAgent.close()
                    return@Thread
                }
                cryptoAgent = currentAgent
                val policy = currentAgent.policyStatus()
                if (!policy.optBoolean("accepted", false)) {
                    Log.w(TAG, "policy rejected; starting HyperBEAM for rejected measurement")
                }
                runtime = HyperbeamRuntime(this, runtimeRoot).also { it.start() }
                if (stopping) {
                    runtime?.close()
                    agent?.close()
                    return@Thread
                }
                hyperbeamRuntime = runtime
                Log.i(TAG, "AndEE service running")
            } catch (exc: Exception) {
                Log.e(TAG, "failed to start AndEE runtime", exc)
                runtime?.close()
                agent?.close()
                stopSelf()
            } finally {
                starterThread = null
            }
        }.also { thread ->
            starterThread = thread
            thread.start()
        }
    }

    override fun onDestroy() {
        stopRuntime()
        super.onDestroy()
    }

    private fun terminateProcess(startId: Int) {
        stopping = true
        stopForegroundCompat()
        stopSelfResult(startId)
        Thread {
            try {
                stopRuntime()
                HyperbeamRuntime.killResidualRuntimeProcesses(this)
            } catch (exc: Exception) {
                Log.e(TAG, "hard terminate cleanup failed", exc)
            } finally {
                Runtime.getRuntime().halt(0)
            }
        }.start()
    }

    @Synchronized
    private fun stopRuntime() {
        hyperbeamRuntime?.close()
        hyperbeamRuntime = null
        cryptoAgent?.close()
        cryptoAgent = null
        starterThread = null
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun notification(): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.notification_channel),
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_andee)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText("Runtime active")
            .setOngoing(true)
            .build()
    }

    private fun foregroundType(): Int {
        return if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
    }

    companion object {
        const val ACTION_STOP = "org.permaweb.andee.action.STOP"
        const val ACTION_TERMINATE = "org.permaweb.andee.action.TERMINATE"
        private const val TAG = "AndeeService"
        private const val CHANNEL_ID = "andee-runtime"
        private const val NOTIFICATION_ID = 7341
    }
}
