package dev.gene.editor

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File

/**
 * Clips a recording to a set of keep-ranges and concatenates them into a single
 * mp4 using Media3 [Transformer]. Must be driven from a thread with a Looper
 * (the platform/main thread); [onResult] is invoked on that same thread.
 *
 * One export runs at a time. A second [tighten] call while an export is in
 * flight is rejected rather than silently clobbering the first.
 */
@UnstableApi
internal class VideoSplicer(private val context: Context) {

    /**
     * A single export, owning its [Transformer]. Once it has reported a result
     * (completed, errored, or cancelled) it is [done] and the splicer drops it.
     */
    private inner class Export(
        private val outputPath: String,
        private val onResult: (Result<String>) -> Unit,
    ) {
        private var transformer: Transformer? = null
        private var done = false

        fun start(composition: Composition) {
            val t = Transformer.Builder(context)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        finish(Result.success(outputPath))
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        finish(Result.failure(exportException))
                    }
                })
                .build()
            transformer = t
            try {
                t.start(composition, outputPath)
            } catch (e: Exception) {
                // start() threw before the listener could fire: release the
                // codec/muxer it may have allocated and report the failure.
                try {
                    t.cancel()
                } catch (_: Exception) {
                }
                finish(Result.failure(e))
            }
        }

        /** Cancel an in-flight export. No result is delivered for a cancel. */
        fun cancel() {
            if (done) return
            done = true
            transformer?.cancel()
            transformer = null
            if (current === this) current = null
            // A cancelled export leaves a truncated mp4 behind; remove it.
            deleteOutput()
        }

        private fun finish(result: Result<String>) {
            if (done) return
            done = true
            transformer = null
            if (current === this) current = null
            // A failed export leaves a partial/truncated mp4 behind; remove it so
            // callers never see a half-written file. (Success keeps the output.)
            if (result.isFailure) deleteOutput()
            onResult(result)
        }

        private fun deleteOutput() {
            try {
                File(outputPath).delete()
            } catch (_: Exception) {
                // Best-effort cleanup; nothing actionable if the delete fails.
            }
        }
    }

    // The in-flight export, or null when idle. Touched only on the Looper thread.
    private var current: Export? = null

    fun tighten(
        inputPath: String,
        ranges: List<KeepRange?>,
        outputPath: String,
        onResult: (Result<String>) -> Unit,
    ) {
        if (current != null) {
            onResult(Result.failure(IllegalStateException("an export is already in progress")))
            return
        }

        val spans = ranges.filterNotNull()
        if (spans.isEmpty()) {
            onResult(Result.failure(IllegalArgumentException("no keep-ranges")))
            return
        }

        val baseItem = MediaItem.fromUri(Uri.fromFile(File(inputPath)))
        val editedItems = spans.map { span ->
            val clipped = baseItem.buildUpon()
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(span.startMs)
                        .setEndPositionMs(span.endMs)
                        .build(),
                )
                .build()
            EditedMediaItem.Builder(clipped).build()
        }

        // Media3 1.9.2 deprecated both item-taking EditedMediaItemSequence.Builder
        // constructors (vararg and List); its only non-deprecated constructor
        // takes a Set<Integer> and there is no no-arg form, while build() and
        // addItem() are fine. The List constructor is the clearest path until a
        // clean items constructor returns — narrowly suppressed, not left to warn.
        @Suppress("DEPRECATION")
        val sequence = EditedMediaItemSequence.Builder(editedItems).build()
        val composition = Composition.Builder(sequence).build()
        File(outputPath).delete()

        val export = Export(outputPath, onResult)
        // Assign `current` BEFORE start(): start() can complete synchronously
        // (e.g. t.start() throws, or the listener fires inline), and finish()/
        // cancel() clear `current` only via `if (current === this)`. If we set
        // `current` after start(), a synchronous finish() would run first, find
        // `current` still null, and then we'd overwrite it with a done Export.
        current = export
        export.start(composition)
    }

    /** Cancel any in-flight export and release its Transformer. Safe when idle. */
    fun cancel() {
        current?.cancel()
        current = null
    }
}
