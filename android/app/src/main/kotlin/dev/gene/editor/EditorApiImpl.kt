package dev.gene.editor

import android.app.Activity
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import java.util.concurrent.Executors

/**
 * Implements the Pigeon-generated [EditorApi] host, delegating to the native
 * engine. Detection is CPU-heavy so it runs on a worker thread; the Media3
 * splice needs a Looper so it runs on the main thread. Both reply via the
 * Pigeon [callback] on the main thread, as Flutter requires.
 */
@UnstableApi
class EditorApiImpl(private val activity: Activity) : EditorApi {

    private val splicer = VideoSplicer(activity)

    // Single worker so detection is serialized and cancelable on teardown.
    private val worker = Executors.newSingleThreadExecutor()

    override fun detectKeepRanges(
        inputPath: String,
        callback: (Result<DetectionResult>) -> Unit,
    ) {
        worker.execute {
            val result = runCatching { AudioAnalyzer.detect(inputPath) }
            // If the decode was cancelled on teardown (shutdownNow -> isInterrupted),
            // re-assert the interrupt flag so the thread's status isn't silently
            // cleared; the failure still flows back as an ordinary Result.
            if (result.exceptionOrNull() is InterruptedException) {
                Thread.currentThread().interrupt()
            }
            // Always complete the Dart Future exactly once, so the awaiting
            // TightenController never hangs with its busy state stuck. Delivery can
            // throw if the engine is detaching during teardown, so guard it — a
            // live Activity always gets its reply rather than a dropped callback.
            activity.runOnUiThread {
                try {
                    callback(result)
                } catch (_: Exception) {
                    // Engine gone; the awaiting Dart side is being torn down too.
                }
            }
        }
    }

    override fun tighten(
        inputPath: String,
        keepRanges: List<KeepRange?>,
        outputPath: String,
        callback: (Result<String>) -> Unit,
    ) {
        // Pigeon handlers run on the main thread, which is what Transformer needs.
        splicer.tighten(inputPath, keepRanges, outputPath, callback)
    }

    /** Release worker + any in-flight export. Call from the Activity teardown. */
    fun dispose() {
        // Interrupts the decode loop (which now polls isInterrupted) so CPU work
        // stops promptly instead of running to completion after teardown.
        worker.shutdownNow()
        // cancel() touches the Transformer, which must happen on the main thread.
        // During teardown a runOnUiThread post can be dropped, so when we are
        // already on the main looper, cancel synchronously; only hop threads when
        // we are off it.
        if (Looper.myLooper() == Looper.getMainLooper()) {
            splicer.cancel()
        } else {
            activity.runOnUiThread { splicer.cancel() }
        }
    }
}
