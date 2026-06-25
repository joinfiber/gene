package dev.gene.editor

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteOrder

/**
 * Finds the speech "keep-ranges" in a recording by analyzing its audio:
 * decode PCM → short-time RMS energy → adaptive (Otsu) silence threshold →
 * trim leading/trailing dead air and collapse long internal pauses.
 *
 * The decision math in [computeKeepRanges], [otsu], and the [Span] helpers is
 * pure (no I/O), which is what makes it unit-testable on the JVM.
 */
internal object AudioAnalyzer {

    private const val WINDOW_S = 0.030      // RMS window
    private const val HOP_S = 0.010         // RMS hop
    private const val DETECT_MIN_S = 0.15   // shortest silence run we consider
    private const val MIN_PAUSE_S = 0.35    // internal pause longer than this is trimmed
    private const val COLLAPSE_TO_S = 0.20  // ...down to this much
    private const val EDGE_S = 0.10         // keep this much at the very start/end

    // A frame's edge is "at" the clip boundary if within this slack (seconds).
    private const val EDGE_SLACK_S = 0.06
    // Below this width a generated keep/cut span is noise; drop it (seconds).
    private const val SPAN_EPS_S = 0.01
    // A leading/trailing edge cut shorter than this isn't worth making (seconds).
    private const val MIN_EDGE_CUT_S = 0.05

    // Decode-loop bounds. A well-formed track terminates long before either of
    // these. The iteration cap is an absolute backstop; the no-progress deadline
    // is the real guard — it counts wall-clock time since the last decoded
    // output so a wedged decoder (endlessly returning INFO_TRY_AGAIN_LATER)
    // fails in seconds instead of spinning idle iterations for minutes.
    private const val MAX_DECODE_ITERATIONS = 5_000_000
    private const val NO_PROGRESS_TIMEOUT_MS = 5_000L

    /** A closed interval [a, b] in seconds. Used for both cut and keep spans. */
    internal data class Span(val a: Double, val b: Double)

    /** Decode + analyze [path], returning the keep-ranges and timing summary. */
    fun detect(path: String): DetectionResult {
        val (audio, sampleRate) = decodeAudioMono(path)
        // Guard before any divide-by-sampleRate (here and in computeKeepRanges).
        if (sampleRate <= 0) throw IllegalStateException("invalid sample rate for $path")
        val ranges = computeKeepRanges(audio, sampleRate)
        val originalMs = audio.size.toLong() * 1000L / sampleRate
        val keptMs = ranges.sumOf { it.endMs - it.startMs }
        return DetectionResult(ranges, originalMs, keptMs)
    }

    /**
     * Decode the first audio track to mono float PCM. The sample rate and
     * channel count are read from the *decoder's* output format (the authority),
     * not the container track, because a decoder may resample/remix.
     */
    private fun decodeAudioMono(path: String): Pair<FloatArray, Int> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            var trackIndex = -1
            var fmt: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) {
                    trackIndex = i
                    fmt = f
                    break
                }
            }
            val format = fmt ?: throw IllegalStateException("no audio track found in $path")
            extractor.selectTrack(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)!!

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val info = MediaCodec.BufferInfo()
            val chunks = ArrayList<FloatArray>()
            var totalLen = 0
            var inputDone = false
            var outputDone = false
            val timeout = 10_000L

            // Authoritative format, filled on INFO_OUTPUT_FORMAT_CHANGED. Seed
            // from the container track so we have sane values even if a decoder
            // never emits a format change (rare, but legal).
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var pcmEncoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                format.getInteger(MediaFormat.KEY_PCM_ENCODING)
            } else {
                AudioFormat.ENCODING_PCM_16BIT
            }

            // Interleaved samples decoded but not yet forming a whole frame,
            // carried across output buffers so trailing samples are never lost.
            var remainder = FloatArray(0)

            var iterations = 0
            var lastProgressAt = System.nanoTime()
            while (!outputDone) {
                // Bail promptly if the worker was interrupted on teardown
                // (shutdownNow); the finally block still releases the codec.
                if (Thread.currentThread().isInterrupted) {
                    throw InterruptedException("decode interrupted for $path")
                }
                if (++iterations > MAX_DECODE_ITERATIONS) {
                    throw IllegalStateException("decode did not terminate for $path")
                }
                if (System.nanoTime() - lastProgressAt > NO_PROGRESS_TIMEOUT_MS * 1_000_000L) {
                    throw IllegalStateException("decode stalled (no output progress) for $path")
                }
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(timeout)
                    if (inIndex >= 0) {
                        val inBuf = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(inBuf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, timeout)
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    // A format change is evidence the decoder is alive: refresh the
                    // no-progress deadline so a slow pipeline warm-up before the
                    // first real output isn't mistaken for a stall.
                    lastProgressAt = System.nanoTime()
                    val out = codec.outputFormat
                    channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    sampleRate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    if (out.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                        pcmEncoding = out.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    }
                } else if (outIndex >= 0) {
                    // Real output dequeued: the decoder is making progress, so
                    // reset the no-progress deadline.
                    lastProgressAt = System.nanoTime()
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                    if (info.size > 0) {
                        val outBuf = codec.getOutputBuffer(outIndex)!!
                        outBuf.position(info.offset)
                        outBuf.limit(info.offset + info.size)
                        val samples = readSamples(outBuf, info.size, pcmEncoding)
                        val mono = downmix(samples, remainder, channels)
                        remainder = mono.leftover
                        if (mono.frames.isNotEmpty()) {
                            chunks.add(mono.frames)
                            totalLen += mono.frames.size
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                }
            }

            if (channels <= 0) throw IllegalStateException("invalid channel count for $path")

            val all = FloatArray(totalLen)
            var off = 0
            for (ch in chunks) {
                System.arraycopy(ch, 0, all, off, ch.size)
                off += ch.size
            }
            return Pair(all, sampleRate)
        } finally {
            // Release on every path. stop() can throw if start() failed, so it
            // is guarded; release() must still run.
            if (codec != null) {
                try {
                    codec.stop()
                } catch (_: IllegalStateException) {
                    // Codec was never started (e.g. configure threw); nothing to stop.
                }
                codec.release()
            }
            extractor.release()
        }
    }

    /** A downmixed buffer plus any interleaved samples that didn't fill a frame. */
    private class Downmixed(val frames: FloatArray, val leftover: FloatArray)

    /**
     * Read [byteCount] bytes of PCM from [buf] as normalized float samples in
     * [-1, 1], branching on the decoder's [pcmEncoding]. Odd/partial trailing
     * bytes (16-bit) are ignored — they cannot form a whole sample.
     */
    private fun readSamples(buf: java.nio.ByteBuffer, byteCount: Int, pcmEncoding: Int): FloatArray {
        return when (pcmEncoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> {
                val n = byteCount / 4
                val src = buf.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                FloatArray(n) { src.get() }
            }
            else -> { // ENCODING_PCM_16BIT (and the safe default)
                val n = byteCount / 2
                val src = buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                FloatArray(n) { src.get() / 32768f }
            }
        }
    }

    /**
     * Downmix interleaved [samples] (prefixed by [leftover] from the prior
     * buffer) to mono, [channels] at a time. Any trailing samples that don't
     * complete a frame become the new leftover, so nothing is dropped.
     */
    private fun downmix(samples: FloatArray, leftover: FloatArray, channels: Int): Downmixed {
        if (channels <= 0) return Downmixed(FloatArray(0), FloatArray(0))
        val total = leftover.size + samples.size
        val frames = total / channels
        val used = frames * channels
        val mono = FloatArray(frames)

        // Read across the leftover→samples boundary without materializing a join.
        fun at(idx: Int): Float =
            if (idx < leftover.size) leftover[idx] else samples[idx - leftover.size]

        var si = 0
        var mi = 0
        while (mi < frames) {
            var acc = 0f
            var c = 0
            while (c < channels) {
                acc += at(si + c)
                c++
            }
            mono[mi] = acc / channels
            si += channels
            mi++
        }

        val rem = total - used
        val nextLeftover = FloatArray(rem) { at(used + it) }
        return Downmixed(mono, nextLeftover)
    }

    /**
     * Pure: turn a mono waveform into the spans worth keeping.
     *
     * Contract: when there is real audio (durMs > 0) the result is one or more
     * valid positive-width keep-ranges — at worst the whole clip when there is
     * nothing to trim. When there is genuinely no audio/duration (durMs <= 0)
     * the result is an EMPTY list. We never emit a zero-width or inverted range
     * (e.g. KeepRange(0, 0)), which would later fail the Media3 export; the Dart
     * caller reads an empty list as "no edit".
     */
    internal fun computeKeepRanges(audio: FloatArray, sampleRate: Int): List<KeepRange> {
        // Symmetric with detect(): never divide by a non-positive sample rate.
        if (sampleRate <= 0) throw IllegalStateException("invalid sample rate")
        val durMs = audio.size.toLong() * 1000L / sampleRate
        val durSec = audio.size.toDouble() / sampleRate
        // No real duration: there is nothing to keep. Return empty rather than a
        // degenerate KeepRange(0, 0).
        if (durMs <= 0L) return emptyList()
        val frame = (sampleRate * WINDOW_S).toInt()
        val hop = (sampleRate * HOP_S).toInt()
        if (audio.size < frame || hop <= 0) return listOf(KeepRange(0L, durMs))
        val nfr = (audio.size - frame) / hop
        if (nfr < 3) return listOf(KeepRange(0L, durMs))

        val db = FloatArray(nfr)
        for (k in 0 until nfr) {
            val start = k * hop
            val end = start + frame
            var sum = 0.0
            var i = start
            while (i < end) {
                val v = audio[i]
                sum += v * v
                i++
            }
            val rms = Math.sqrt(sum / frame + 1e-12)
            db[k] = (20.0 * Math.log10(rms + 1e-9)).toFloat()
        }
        // 50 ms (5-frame) smoothing
        val sm = FloatArray(nfr)
        for (k in 0 until nfr) {
            var s = 0f
            var c = 0
            var j = k - 2
            while (j <= k + 2) {
                if (j in 0 until nfr) {
                    s += db[j]
                    c++
                }
                j++
            }
            sm[k] = s / c
        }

        val thr = otsu(sm)
        val silent = BooleanArray(nfr) { sm[it] < thr }
        fun tAt(k: Int) = k.toDouble() * hop / sampleRate

        // 1. Detect silence runs >= DETECT_MIN_S as spans.
        val silences = ArrayList<Span>()
        var i = 0
        while (i < nfr) {
            if (silent[i]) {
                var j = i
                while (j < nfr && silent[j]) j++
                val a = tAt(i)
                val b = tAt(j)
                if (b - a >= DETECT_MIN_S) silences.add(Span(a, b))
                i = j
            } else {
                i++
            }
        }

        // 2. Turn silences into cut spans, each clamped inside its own run.
        val cuts = toCuts(silences, durSec)

        // 3. Merge overlapping/adjacent cuts, then complement to keep-ranges.
        val merged = mergeSpans(cuts)
        return complement(merged, durSec, durMs)
    }

    /**
     * Map detected silence [silences] to cut spans over a clip of [durSec]:
     *  - leading silence: cut from 0 up to its end minus an [EDGE_S] tail,
     *  - trailing silence: cut from its start plus an [EDGE_S] lead to the end,
     *  - a pause touching *both* edges (whole clip silent): keep only a minimal
     *    leading stub so the result is non-empty and exportable,
     *  - a long internal pause: collapse to [COLLAPSE_TO_S], the removed excess
     *    centered in and clamped to the run so the cut never exceeds it.
     */
    internal fun toCuts(silences: List<Span>, durSec: Double): List<Span> {
        val cuts = ArrayList<Span>()
        for (s in silences) {
            val atStart = s.a <= EDGE_SLACK_S
            val atEnd = s.b >= durSec - EDGE_SLACK_S
            when {
                atStart && atEnd -> {
                    // Silence spans the whole clip. Nothing is worth keeping, but
                    // an empty result can't be exported, so keep a minimal leading
                    // stub (cut everything after it) rather than the whole clip.
                    val stub = Math.min(EDGE_S, durSec)
                    if (durSec - stub > SPAN_EPS_S) cuts.add(Span(stub, durSec))
                }
                atStart -> {
                    val e = Math.max(0.0, s.b - EDGE_S)
                    if (e > MIN_EDGE_CUT_S) cuts.add(Span(0.0, e))
                }
                atEnd -> {
                    val start = Math.min(durSec, s.a + EDGE_S)
                    if (durSec - start > MIN_EDGE_CUT_S) cuts.add(Span(start, durSec))
                }
                s.b - s.a > MIN_PAUSE_S -> {
                    val excess = (s.b - s.a) - COLLAPSE_TO_S
                    val mid = (s.a + s.b) / 2
                    // Clamp the cut to the run so a centered window can't spill out.
                    val a = Math.max(s.a, mid - excess / 2)
                    val b = Math.min(s.b, mid + excess / 2)
                    if (b - a > SPAN_EPS_S) cuts.add(Span(a, b))
                }
                // No `else`: an internal silence run in [DETECT_MIN_S, MIN_PAUSE_S]
                // is short enough to be natural speech rhythm, so it is kept whole
                // (no cut emitted) — only pauses longer than MIN_PAUSE_S collapse.
            }
        }
        return cuts
    }

    /** Merge overlapping or touching spans into a sorted, disjoint list. */
    internal fun mergeSpans(spans: List<Span>): List<Span> {
        if (spans.isEmpty()) return emptyList()
        val sorted = spans.sortedBy { it.a }
        val out = ArrayList<Span>()
        var cur = sorted[0]
        for (k in 1 until sorted.size) {
            val s = sorted[k]
            if (s.a <= cur.b) {
                // Overlapping/adjacent: extend the current span.
                cur = Span(cur.a, Math.max(cur.b, s.b))
            } else {
                out.add(cur)
                cur = s
            }
        }
        out.add(cur)
        return out
    }

    /**
     * Keep-ranges = complement of the (sorted, disjoint) [cuts] over [0, durSec].
     * A monotonic guard (`prev = max(prev, cut.b)`) keeps the cursor advancing
     * even if a cut starts before the previous one ended.
     *
     * Returns an empty list when there is no positive duration to keep, never a
     * degenerate KeepRange(0, 0): the all-cut fallback only fires when the clip
     * actually has duration (durMs > 0).
     */
    internal fun complement(cuts: List<Span>, durSec: Double, durMs: Long): List<KeepRange> {
        if (durMs <= 0L) return emptyList()
        val keeps = ArrayList<KeepRange>()
        var prev = 0.0
        for (c in cuts) {
            if (c.a - prev > SPAN_EPS_S) {
                keeps.add(KeepRange((prev * 1000).toLong(), (c.a * 1000).toLong()))
            }
            prev = Math.max(prev, c.b)
        }
        if (durSec - prev > SPAN_EPS_S) keeps.add(KeepRange((prev * 1000).toLong(), durMs))
        if (keeps.isEmpty()) keeps.add(KeepRange(0L, durMs))
        return keeps
    }

    /** Otsu's method: parameter-free split between the silence and speech clusters. */
    internal fun otsu(values: FloatArray, bins: Int = 256): Float {
        var min = Float.MAX_VALUE
        var max = -Float.MAX_VALUE
        for (v in values) {
            if (v < min) min = v
            if (v > max) max = v
        }
        if (max <= min) return min
        // One scale convention: bin width = (max-min)/bins. Index and center
        // both use it, so center[index(v)] is the bin v actually falls in.
        val width = (max - min) / bins
        val hist = IntArray(bins)
        for (v in values) {
            var b = ((v - min) / width).toInt()
            if (b < 0) b = 0
            if (b >= bins) b = bins - 1
            hist[b]++
        }
        val centers = FloatArray(bins) { min + (it + 0.5f) * width }
        val total = values.size.toDouble()
        var sumAll = 0.0
        for (b in 0 until bins) sumAll += hist[b] * centers[b]
        var wB = 0.0
        var sumB = 0.0
        var best = min
        var bestVar = -1.0
        for (b in 0 until bins) {
            wB += hist[b]
            if (wB == 0.0) continue
            val wF = total - wB
            if (wF <= 0.0) break
            sumB += hist[b] * centers[b]
            val mB = sumB / wB
            val mF = (sumAll - sumB) / wF
            val between = wB * wF * (mB - mF) * (mB - mF)
            if (between > bestVar) {
                bestVar = between
                best = centers[b]
            }
        }
        return best
    }
}
