package com.example.frontend

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CallLog
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reads how often each phone number is called.
 *
 * Why this exists instead of asking the user to pick from their contacts:
 *
 * A phone can hold 100 to 500 contacts. Reading them out, even four at a time,
 * is not a selection interface - it is a chore, and a blind user has to
 * remember which number they heard and in what order. The people who matter
 * are almost always the handful the user actually calls.
 *
 * So the app proposes the shortlist itself: the numbers in the device call log,
 * ranked by how often they were called and how recently. The user confirms the
 * first suggestion, says "alternative" to hear the next candidate, or names
 * anyone directly. Nothing is chosen automatically and nothing is sent anywhere
 * - the call log stays on the device.
 *
 * [ContactsContract.Contacts.TIMES_CONTACTED] would have been the tidier
 * source, but `contacts_service_plus` does not expose it, and reading it here
 * would mean re-querying the contacts provider directly. The call log is the
 * signal the user actually described, and it is the same data the phone dialler
 * ranks by.
 */
class CallLogBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "my_eyes/call_log"
        private const val TAG = "myeyes.calllog"
        private const val REQUEST_CALL_LOG = 9201

        /**
         * Hard cap on rows scanned.
         *
         * A heavy user can have tens of thousands of call-log entries, and the
         * ranking only needs the people who are called at all. Bounding the scan
         * keeps this from ever blocking the emergency setup wizard for long.
         * The query is ordered newest-first, so the budget is spent on the calls
         * that actually reflect how the user lives now.
         */
        private const val MAX_ROWS = 4000
    }

    private val context: Context get() = activity.applicationContext

    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        if (channel != null) return
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler(this@CallLogBridge)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadCallFrequency" -> {
                if (!hasPermission()) {
                    requestPermission(result)
                } else {
                    result.success(query())
                }
            }

            "hasPermission" -> result.success(hasPermission())

            else -> result.notImplemented()
        }
    }

    /**
     * Framework permission checks rather than the AndroidX helpers.
     *
     * `Context.checkSelfPermission` and `Activity.requestPermissions` are both
     * API 23, and this app's minSdk is 24, so the support-library indirection
     * buys nothing here. Dropping it also removes the reason this bridge needs
     * an Activity at all - the permission request can only be made from one.
     */
    private fun hasPermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.READ_CALL_LOG) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Asks for call-log access and reports the answer through the pending result.
     *
     * Declining is not an error: the caller falls back to the contacts list, so
     * the user is never blocked from setting up emergency contacts.
     */
    private fun requestPermission(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.success(
                errorMap("busy", "A call-log permission request is already open")
            )
            return
        }
        pendingResult = result
        try {
            activity.requestPermissions(
                arrayOf(Manifest.permission.READ_CALL_LOG),
                REQUEST_CALL_LOG
            )
        } catch (error: Exception) {
            Log.e(TAG, "could not request READ_CALL_LOG", error)
            pendingResult = null
            result.success(errorMap("request_failed", error.message))
        }
    }

    /** Delivers the permission outcome once Android answers. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_CALL_LOG) return
        val pending = pendingResult
        pendingResult = null
        if (pending == null) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED

        pending.success(
            if (granted) query() else errorMap("denied", "Call log permission was declined")
        )
    }

    /**
     * Counts calls per number, newest first.
     *
     * Missed calls are excluded on purpose. A missed call from a telemarketer
     * is a high-volume signal about exactly the wrong person, and an emergency
     * shortlist full of spam callers is worse than no shortlist at all.
     *
     * Note the `_TYPE` suffix on the platform constants. They used to be
     * `CallLog.Calls.MISSED` and friends; current SDKs only expose
     * `MISSED_TYPE`, `INCOMING_TYPE`, `OUTGOING_TYPE` and the rest, and the
     * short names no longer resolve at compile time.
     */
    private fun query(): Map<String, Any> {
        return try {
            val uri = CallLog.Calls.CONTENT_URI

            // DATE is in the projection because recency breaks ties between two
            // numbers called equally often. Without it `getColumnIndex` returns
            // -1, the recency is silently skipped, and the ranking quietly
            // degrades to call count plus alphabetical order.
            val projection = arrayOf(
                CallLog.Calls.NUMBER,
                CallLog.Calls.TYPE,
                CallLog.Calls.DATE
            )

            // Newest first, so the MAX_ROWS cap bounds the scan to the most
            // recent calls. A provider returns rows in insertion order, so an
            // unsorted query would spend the whole budget on the oldest history
            // and rank a user by what they called years ago.
            val sortOrder = "${CallLog.Calls.DATE} DESC"

            val selection = "${CallLog.Calls.TYPE} <> ?"
            val selectionArgs = arrayOf(CallLog.Calls.MISSED_TYPE.toString())

            val counts = HashMap<String, Int>()
            val lastSeen = HashMap<String, Long>()

            context.contentResolver.query(
                uri, projection, selection, selectionArgs, sortOrder
            )?.use { cursor ->
                val numberIndex = cursor.getColumnIndex(CallLog.Calls.NUMBER)
                val dateIndex = cursor.getColumnIndex(CallLog.Calls.DATE)
                var scanned = 0

                while (cursor.moveToNext() && scanned < MAX_ROWS) {
                    scanned++
                    val raw = if (numberIndex >= 0) cursor.getString(numberIndex) else null
                    if (raw.isNullOrBlank()) continue

                    val key = normalise(raw) ?: continue
                    counts[key] = (counts[key] ?: 0) + 1

                    if (dateIndex >= 0) {
                        val date = cursor.getLong(dateIndex)
                        if (date > (lastSeen[key] ?: 0L)) lastSeen[key] = date
                    }
                }
            }

            val rows = counts.map { (number, count) ->
                hashMapOf<String, Any>(
                    "number" to number,
                    "count" to count,
                    "lastCall" to (lastSeen[number] ?: 0L)
                )
            }.sortedWith(
                // Most called first; ties broken by most recent, so a number the
                // user still uses beats an equally frequent stale one.
                compareByDescending<Map<String, Any>> { it["count"] as Int }
                    .thenByDescending { it["lastCall"] as Long }
            )

            hashMapOf<String, Any>("status" to "ok", "entries" to rows)
        } catch (error: SecurityException) {
            Log.w(TAG, "call log read was refused: ${error.message}")
            errorMap("denied", error.message ?: "Call log permission was refused")
        } catch (error: Exception) {
            Log.e(TAG, "could not read the call log", error)
            errorMap("failed", error.message ?: "Could not read the call log")
        }
    }

    /**
     * Reduces a stored number to comparable digits.
     *
     * Numbers are stored inconsistently across apps and countries ("+91
     * 98765-43210", "09876543210", "9876543210"), so the same person can appear
     * as several entries. Everything but the digits is dropped, and a leading
     * country code is handled on the Dart side where the user's locale is
     * known.
     */
    private fun normalise(raw: String): String? {
        val digits = raw.filter { it.isDigit() }
        if (digits.length < 7) return null
        return digits
    }

    private fun errorMap(code: String, message: String?): Map<String, Any> =
        hashMapOf<String, Any>("status" to code, "message" to (message ?: code))

    /** Drops a pending permission result so a rotation cannot leak it. */
    fun dispose() {
        pendingResult = null
    }
}
