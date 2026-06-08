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
            // The Activity may have been torn down while we were decoding;
            // runOnUiThread on a dead Activity would be wasted work or worse.
            if (!activity.isDestroyed && !activity.isFinishing) {
                activity.runOnUiThread { callback(result) }
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
