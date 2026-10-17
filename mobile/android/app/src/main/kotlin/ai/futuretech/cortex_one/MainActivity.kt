package ai.futuretech.cortex_one

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth (biometric / screen-lock prompt for confirmations) needs a FragmentActivity.
// Gateway mode (Cortex Wake) talks to this activity over one MethodChannel: runtime permissions
// and starting / stopping the foreground service. UNVERIFIED on a real phone.
class MainActivity : FlutterFragmentActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    private fun neededPermissions(): Array<String> {
        val list = mutableListOf(Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS)
        if (Build.VERSION.SDK_INT >= 31) {
            list += Manifest.permission.BLUETOOTH_SCAN
            list += Manifest.permission.BLUETOOTH_CONNECT
        } else {
            list += Manifest.permission.ACCESS_FINE_LOCATION // old Android needs it to scan BLE
        }
        if (Build.VERSION.SDK_INT >= 33) list += Manifest.permission.POST_NOTIFICATIONS
        return list.toTypedArray()
    }

    private fun hasAll(): Boolean = neededPermissions().all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GatewayBridge.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermissions" -> result.success(hasAll())
                    "requestPermissions" -> {
                        if (hasAll()) {
                            result.success(true)
                        } else if (pendingPermissionResult != null) {
                            result.error("busy", "A permission request is already open", null)
                        } else {
                            pendingPermissionResult = result
                            ActivityCompat.requestPermissions(this, neededPermissions(), 4711)
                        }
                    }
                    "startService" -> {
                        if (!hasAll()) {
                            result.error("permissions", "Permissions are missing", null)
                        } else {
                            getSharedPreferences(GatewayBridge.PREFS, Context.MODE_PRIVATE)
                                .edit().putBoolean("enabled", true).apply()
                            ContextCompat.startForegroundService(
                                this, Intent(this, GatewayService::class.java))
                            result.success(null)
                        }
                    }
                    "stopService" -> {
                        getSharedPreferences(GatewayBridge.PREFS, Context.MODE_PRIVATE)
                            .edit().putBoolean("enabled", false).apply()
                        stopService(Intent(this, GatewayService::class.java))
                        result.success(null)
                    }
                    "isRunning" -> result.success(GatewayService.running)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4711) {
            pendingPermissionResult?.success(hasAll())
            pendingPermissionResult = null
        }
    }
}
