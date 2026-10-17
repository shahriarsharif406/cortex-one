package ai.futuretech.cortex_one

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Hands incoming SMS to the Dart gateway logic (which holds the secrets and makes every
 * decision). A message that arrives before the Dart engine is ready waits in a tiny queue
 * (at most 5, at most 2 minutes). The SMS text is never logged here.
 */
object GatewayBridge {
    const val CHANNEL = "ai.futuretech.cortex_one/gateway"
    const val PREFS = "cortex_gateway"
    private const val MAX_QUEUE = 5
    private const val MAX_AGE_MS = 120_000L

    private var channel: MethodChannel? = null
    private val queue = ArrayDeque<Triple<String, String, Long>>()
    private val main = Handler(Looper.getMainLooper())

    fun attach(ch: MethodChannel) {
        channel = ch
        while (queue.isNotEmpty()) {
            val (sender, body, at) = queue.removeFirst()
            if (System.currentTimeMillis() - at <= MAX_AGE_MS) send(sender, body)
        }
    }

    fun detach() {
        channel = null
    }

    fun deliver(context: Context, sender: String, body: String) {
        if (channel != null) {
            send(sender, body)
            return
        }
        queue.addLast(Triple(sender, body, System.currentTimeMillis()))
        while (queue.size > MAX_QUEUE) queue.removeFirst()
        // Fallback only: the owner normally starts the service from the app. Newer Android may
        // refuse to start a foreground service from the background; then the SMS is dropped.
        try {
            ContextCompat.startForegroundService(context, Intent(context, GatewayService::class.java))
        } catch (_: Exception) {
        }
    }

    private fun send(sender: String, body: String) {
        main.post { channel?.invokeMethod("onSms", mapOf("sender" to sender, "body" to body)) }
    }
}
