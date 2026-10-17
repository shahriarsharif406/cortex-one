package ai.futuretech.cortex_one

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * Receives SMS only while gateway mode is switched on. It forwards (sender, text) to the Dart
 * gateway logic and nothing else: no logging of the text, no storage. Declared with the
 * BROADCAST_SMS permission so only the system can deliver to it.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val enabled = context.getSharedPreferences(GatewayBridge.PREFS, Context.MODE_PRIVATE)
            .getBoolean("enabled", false)
        if (!enabled) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val bySender = LinkedHashMap<String, StringBuilder>()
        for (p in parts) {
            val from = p.originatingAddress ?: continue
            bySender.getOrPut(from) { StringBuilder() }.append(p.messageBody ?: "")
        }
        for ((from, body) in bySender) {
            GatewayBridge.deliver(context, from, body.toString().take(200))
        }
    }
}
