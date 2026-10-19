package com.example.frontend

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The SOS alarm.
 *
 * Why this exists instead of Dart's `SystemSound.play`:
 *
 * Flutter implements `SystemSound.play(SystemSoundType.alert)` on Android as a
 * `ToneGenerator` beep of roughly 150 ms on `AudioManager.STREAM_SYSTEM`.
 * That produces three failures for an emergency alarm:
 *
 *  1. `STREAM_SYSTEM` is the notification/system stream. It is muted whenever
 *     the phone is silenced or set to vibrate-only - exactly the state a phone
 *     is in when an alarm is needed most.
 *  2. 150 ms once every two seconds is a tick, not an alarm. It is easily
 *     missed and does not read as an emergency to anyone nearby.
 *  3. It is not loud. The ToneGenerator is built from the system volume, so a
 *     user who muted notifications hears nothing at all.
 *
 * This bridge plays the device's own alarm ringtone on `USAGE_ALARM`, looping
 * continuously, and runs a repeating vibration waveform beside it. It also owns
 * its own deadline, so the alarm keeps sounding for the full duration even if
 * the Dart side is throttled or the app is backgrounded while the user is being
 * driven away from the phone - which is the normal case for this feature.
 */
class SosAlarmBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "my_eyes/alarm"
        private const val TAG = "myeyes.sos.alarm"

        /**
         * SOS vibration pattern: buzz, short pause, buzz. `-1` means "do not
         * turn off", which is what makes it repeat until [stopAlarm].
         */
        private val VIBRATE_TIMINGS = longArrayOf(0, 700, 400, 700)
        private val VIBRATE_AMPLITUDES = intArrayOf(0, 255, 0, 255)

        /** Default length when the caller does not specify one. */
        private const val DEFAULT_SECONDS = 300

        /** Upper bound on a single alarm, so a bad argument cannot ring forever. */
        private const val MAX_SECONDS = 3600
    }

    private var player: MediaPlayer? = null
    private val handler = Handler(Looper.getMainLooper())
    private var deadline: Runnable? = null

    private var channel: MethodChannel? = null

    /** Registers the method channel that Dart calls. Idempotent. */
    fun register(messenger: BinaryMessenger) {
        if (channel != null) return
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler(this@SosAlarmBridge)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startAlarm" -> {
                val seconds = (call.argument<Int>("seconds") ?: DEFAULT_SECONDS)
                start(seconds.coerceIn(1, MAX_SECONDS))
                result.success(true)
            }

            "stopAlarm" -> {
                stop()
                result.success(true)
            }

            "isAlarmPlaying" -> result.success(isPlaying)

            else -> result.notImplemented()
        }
    }

    /** True when a ringtone or a vibration is currently running. */
    val isPlaying: Boolean
        get() = player?.isPlaying == true || vibrateRunning

    private var vibrateRunning = false

    /**
     * Starts (or restarts) the alarm for [seconds].
     *
     * Restarting is deliberate and safe: a user who triggers SOS twice gets a
     * full-length alarm rather than a no-op.
     */
    @Synchronized
    private fun start(seconds: Int) {
        stop()

        // ---- sound ---------------------------------------------------
        val uri = alarmUri()
        if (uri != null) {
            try {
                val mp = MediaPlayer()
                mp.setAudioAttributes(
                    AudioAttributes.Builder()
                        // USAGE_ALARM is what makes this compete with (and win
                        // against) the speech synthesiser during an emergency.
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                mp.setDataSource(context, uri)
                mp.isLooping = true
                mp.setVolume(1f, 1f)
                mp.setOnErrorListener { _, what, extra ->
                    Log.w(TAG, "alarm playback error what=$what extra=$extra")
                    true // handled: do not abort, the vibration still runs
                }
                mp.prepare()
                mp.start()
                player = mp
            } catch (error: Exception) {
                Log.e(TAG, "could not start the alarm ringtone", error)
                player = null
            }
        } else {
            Log.w(TAG, "no alarm or ringtone URI on this device")
        }

        // ---- vibration ----------------------------------------------
        vibrateRunning = startVibration()

        // ---- deadline ------------------------------------------------
        // Owned here, not by Dart, so the alarm keeps its full length even if
        // the Dart timer is throttled in the background.
        val stop = Runnable { stop() }
        deadline = stop
        handler.postDelayed(stop, seconds * 1000L)

        Log.i(TAG, "alarm started for $seconds s (vibrating=$vibrateRunning)")
    }

    /** Stops the alarm. Safe to call when nothing is playing. */
    @Synchronized
    fun stop() {
        deadline?.let { handler.removeCallbacks(it) }
        deadline = null

        try {
            player?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (error: Exception) {
            Log.e(TAG, "could not stop the alarm ringtone", error)
        }
        player = null

        stopVibration()
        vibrateRunning = false

        Log.i(TAG, "alarm stopped")
    }

    // ------------------------------------------------------------------
    // Ringtone
    // ------------------------------------------------------------------

    /**
     * The device's alarm sound, falling back through ringtone and notification
     * so a phone with no alarm sound installed still makes noise.
     */
    private fun alarmUri(): Uri? =
        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

    // ------------------------------------------------------------------
    // Vibration
    // ------------------------------------------------------------------

    private fun vibrator(): Vibrator? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager =
                context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    } catch (error: Exception) {
        Log.e(TAG, "no vibrator service", error)
        null
    }

    private fun startVibration(): Boolean {
        val vib = vibrator() ?: return false
        return try {
            if (!vib.hasVibrator()) {
                Log.w(TAG, "device reports no vibrator")
                return false
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vib.vibrate(
                    VibrationEffect.createWaveform(
                        VIBRATE_TIMINGS,
                        VIBRATE_AMPLITUDES,
                        // repeat from index 0 forever
                        0,
                    )
                )
            } else {
                @Suppress("DEPRECATION")
                vib.vibrate(VIBRATE_TIMINGS, 0)
            }
            true
        } catch (error: Exception) {
            Log.e(TAG, "could not start the vibration", error)
            false
        }
    }

    private fun stopVibration() {
        try {
            vibrator()?.cancel()
        } catch (error: Exception) {
            Log.e(TAG, "could not stop the vibration", error)
        }
    }

    /** Frees the media player if the activity is being torn down. */
    fun dispose() {
        handler.post { stop() }
    }
}