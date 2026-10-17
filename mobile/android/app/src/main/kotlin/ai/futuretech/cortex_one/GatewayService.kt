package ai.futuretech.cortex_one

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.telephony.SmsManager
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Foreground service that keeps a headless Flutter engine (entry point `gatewayMain`) alive so
 * incoming SMS can be handled while the app is closed. A visible notification says so.
 * UNVERIFIED on a real phone: battery optimisation or the OEM may still kill it.
 */
class GatewayService : Service() {
    private var engine: FlutterEngine? = null

    companion object {
        @Volatile var running = false
        private const val CHANNEL_ID = "cortex_wake_gateway"
        private val NUMBER = Regex("^\\+?[0-9]{6,15}$")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        if (engine == null) startEngine()
        running = true
        return START_STICKY
    }

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Cortex Wake gateway", NotificationManager.IMPORTANCE_LOW))
        }
        val n: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Cortex Wake gateway is on")
            .setContentText("Listening for SMS commands from your allowed numbers")
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(4712, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(4712, n)
        }
    }

    private fun startEngine() {
        val e = FlutterEngine(this)
        GeneratedPluginRegistrant.registerWith(e)
        val ch = MethodChannel(e.dartExecutor.binaryMessenger, GatewayBridge.CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "engineReady" -> {
                    GatewayBridge.attach(ch)
                    result.success(null)
                }
                "sendSms" -> {
                    val to = call.argument<String>("to") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    if (!NUMBER.matches(to) || text.isEmpty() || text.length > 320) {
                        result.error("bad_args", "Not sent", null)
                    } else {
                        try {
                            val sms = if (Build.VERSION.SDK_INT >= 31)
                                getSystemService(SmsManager::class.java) else SmsManager.getDefault()
                            sms.sendMultipartTextMessage(to, null, sms.divideMessage(text), null, null)
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("send_failed", "Not sent", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(), "gatewayMain"))
        engine = e
    }

    override fun onDestroy() {
        running = false
        GatewayBridge.detach()
        engine?.destroy()
        engine = null
        super.onDestroy()
    }
}
