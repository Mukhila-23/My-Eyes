package com.example.frontend

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayList

// local_auth requires FragmentActivity so Android can display BiometricPrompt.
// Google account selection is handled by the google_sign_in Flutter plugin.
// It owns the Google authentication UI and must not be routed through the old
// AccountManager chooser, which can redirect to Android's Add account screen.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val UPI_CHANNEL = "my_eyes/upi"
        private const val REQUEST_UPI = 9101

        /// Google Pay: the payment app My Eyes supports.
        private const val PREFERRED_UPI_PACKAGE =
            "com.google.android.apps.nbu.paisa.user"
    }

    private var pendingUpiResult: MethodChannel.Result? = null

    /**
     * The SOS alarm, owned here rather than by a Dart timer.
     *
     * Lives on the Activity so the ringtone and vibration keep sounding for the
     * full five minutes even while Dart is throttled in the background - which
     * is the normal state once the user puts the phone down and runs for help.
     */
    private var alarmBridge: SosAlarmBridge? = null

    /**
     * Call history, used to rank the emergency-contact shortlist.
     *
     * Reads happen on this side because `contacts_service_plus` exposes no call
     * frequency, and because the query has to be bounded and de-duplicated
     * before it crosses the channel.
     */
    private var callLogBridge: CallLogBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        alarmBridge = SosAlarmBridge(applicationContext).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }

        callLogBridge = CallLogBridge(this).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UPI_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "launchPayment" -> launchPayment(call, result)
                "availableApps" -> availableApps(call, result)
                "preferredPackage" -> result.success(PREFERRED_UPI_PACKAGE)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Forwards the call-log permission outcome to the bridge.
     *
     * The request is made from the bridge so the read and its permission live
     * together; the answer has to come back here because only the Activity sees
     * the system callback.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        callLogBridge?.onRequestPermissionsResult(requestCode, grantResults)
    }

    // ------------------------------------------------------------------
    // UPI
    // ------------------------------------------------------------------

    /**
     * Launches the real payment app and reports its actual response.
     */
    private fun launchPayment(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val uri = call.argument<String>("uri")

        if (uri.isNullOrBlank()) {
            result.error(
                "bad_request",
                "No payment URI provided",
                null
            )
            return
        }

        val requestedPackage = call.argument<String>("package")
            ?.takeIf { it.isNotBlank() }
            ?: PREFERRED_UPI_PACKAGE

        if (pendingUpiResult != null) {
            result.error(
                "busy",
                "Another payment is already in progress",
                null
            )
            return
        }

        // IMPORTANT:
        // resolveUpiActivity() returns ActivityInfo directly.
        // Therefore target itself is the ActivityInfo.
        val target = resolveUpiActivity(
            uri,
            requestedPackage
        )

        if (target == null) {
            result.error(
                "no_app",
                "No installed app can handle a UPI payment link. Install Google Pay and complete its setup, then try again.",
                null
            )
            return
        }

        // target is already ActivityInfo.
        val intent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse(uri)
        ).apply {
            component = android.content.ComponentName(
                target.packageName,
                target.name
            )

            addCategory(Intent.CATEGORY_BROWSABLE)
            addCategory(Intent.CATEGORY_DEFAULT)
        }

        pendingUpiResult = result

        try {
            startActivityForResult(
                intent,
                REQUEST_UPI
            )
        } catch (error: ActivityNotFoundException) {
            pendingUpiResult = null

            result.error(
                "launch_failed",
                "Google Pay could not be opened. Open it once and complete its setup, then try again.",
                error.message
            )
        } catch (error: Exception) {
            pendingUpiResult = null

            result.error(
                "launch_failed",
                error.message ?: "Payment launch failed",
                null
            )
        }
    }

    // ------------------------------------------------------------------
    // FIND AVAILABLE UPI APPS
    // ------------------------------------------------------------------

    /**
     * Returns installed apps that can handle a UPI payment URI.
     */
    private fun availableApps(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val uri = call.argument<String>("uri")

        if (uri.isNullOrBlank()) {
            result.error(
                "bad_request",
                "No payment URI provided",
                null
            )
            return
        }

        try {
            val seen = HashSet<String>()
            val apps = ArrayList<HashMap<String, String>>()

            for (info in resolveInfosForUpi(uri, null)) {

                val activityInfo = info.activityInfo
                    ?: continue

                val packageName = activityInfo.packageName

                if (packageName.isNullOrBlank()) {
                    continue
                }

                if (!seen.add(packageName)) {
                    continue
                }

                val label = runCatching {
                    activityInfo
                        .loadLabel(packageManager)
                        .toString()
                }
                    .getOrNull()
                    ?.trim()
                    ?.ifEmpty { packageName }
                    ?: packageName

                apps.add(
                    hashMapOf(
                        "label" to label,
                        "package" to packageName,
                        "preferred" to (
                            packageName == PREFERRED_UPI_PACKAGE
                        ).toString()
                    )
                )
            }

            // Put the preferred payment application first.
            apps.sortWith(
                compareByDescending<HashMap<String, String>> {
                    it["preferred"] == "true"
                }.thenBy {
                    it["label"]?.lowercase() ?: ""
                }
            )

            result.success(apps)

        } catch (error: Exception) {
            result.error(
                "app_query_failed",
                error.message ?: "Could not find UPI payment apps",
                null
            )
        }
    }

    // ------------------------------------------------------------------
    // RESOLVE UPI ACTIVITIES
    // ------------------------------------------------------------------

    /**
     * Every activity that can handle [uri], optionally restricted to one
     * package.
     */
    private fun resolveInfosForUpi(
        uri: String,
        packageName: String?
    ): List<ResolveInfo> {

        val intent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse(uri)
        ).apply {

            if (!packageName.isNullOrBlank()) {
                this.`package` = packageName
            }
        }

        return packageManager.queryIntentActivities(
            intent,
            PackageManager.MATCH_DEFAULT_ONLY
        )
    }

    /**
     * Returns the single best ActivityInfo for the UPI URI.
     *
     * First tries the preferred package.
     * If that fails, falls back to any available UPI application.
     */
    private fun resolveUpiActivity(
        uri: String,
        packageName: String
    ): ActivityInfo? {

        // 1. Try the requested/preferred application.
        val preferred = resolveInfosForUpi(
            uri,
            packageName
        )

        if (preferred.isNotEmpty()) {
            return preferred.first().activityInfo
        }

        // 2. Fall back to any installed UPI application.
        return resolveInfosForUpi(
            uri,
            null
        ).firstOrNull()?.activityInfo
    }

    // ------------------------------------------------------------------
    // UPI RESULT
    // ------------------------------------------------------------------

    @Suppress("DEPRECATION")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(
            requestCode,
            resultCode,
            data
        )

        if (requestCode != REQUEST_UPI) {
            return
        }

        val pending = pendingUpiResult
        pendingUpiResult = null


        if (pending == null) {
            return
        }

        val response = when {

            resultCode == Activity.RESULT_OK -> {
                data?.getStringExtra("response")
                    ?: data?.getStringExtra("Response")
                    ?: data?.dataString
            }

            else -> null
        }

        pending.success(
            hashMapOf(
                "resultCode" to resultCode,
                "response" to response,
                "resultOk" to (
                    resultCode == Activity.RESULT_OK
                )
            )
        )
    }

    // ------------------------------------------------------------------
    // CLEANUP
    // ------------------------------------------------------------------

    override fun onDestroy() {
        pendingUpiResult = null
        // Release the alarm's MediaPlayer. The alarm itself is deliberately NOT
        // stopped here: leaving the SOS screen must not silence an emergency.
        // A configuration change recreates the activity, so the bridge is
        // rebuilt and the alarm keeps going.
        alarmBridge?.dispose()
        alarmBridge = null
        callLogBridge?.dispose()
        callLogBridge = null
        super.onDestroy()
    }
}