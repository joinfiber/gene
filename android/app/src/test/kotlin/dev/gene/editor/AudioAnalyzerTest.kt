package dev.gene.editor

import dev.gene.editor.AudioAnalyzer.Span
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sin

/**
 * Pure-JVM tests for the editing decision math. The hardware-bound decode path
 * ([AudioAnalyzer.decodeAudioMono]) is exercised on-device, not here.
 *
 * The keep-range pipeline is silence-spans → [AudioAnalyzer.toCuts] →
 * [AudioAnalyzer.mergeSpans] → [AudioAnalyzer.complement]. The end-to-end tests
 * drive synthesized audio through [AudioAnalyzer.computeKeepRanges]; the edge
 * cases exercise the pure interval primitives directly, since reliably coaxing
 * the adaptive (Otsu) detector into, say, classifying an entire clip as silent
 * is brittle whereas the interval algebra is exact.
 */
class AudioAnalyzerTest {

    @Test
    fun `otsu finds a threshold between two energy clusters`() {
        // 200 "silent" frames at -60 dB, 200 "speech" frames at -10 dB.
        val values = FloatArray(400) { if (it < 200) -60f else -10f }
        val threshold = AudioAnalyzer.otsu(values)
        assertTrue(
            "threshold $threshold should sit between the clusters",
            threshold > -60f && threshold < -10f,
        )
    }

    @Test
    fun `computeKeepRanges trims a long internal pause but keeps the speech`() {
        val sampleRate = 16000
        val audio = FloatArray((sampleRate * 3.5).toInt())
        for (i in audio.indices) {
            val t = i.toDouble() / sampleRate
            audio[i] = when {
                t < 1.0 -> 0.3f * sin(2 * Math.PI * 220 * t).toFloat()   // speech
                t < 2.5 -> 0.0005f * sin(2 * Math.PI * 50 * t).toFloat() // ~silence
                else -> 0.3f * sin(2 * Math.PI * 220 * t).toFloat()      // speech
            }
        }

        val ranges = AudioAnalyzer.computeKeepRanges(audio, sampleRate)
        val originalMs = audio.size.toLong() * 1000 / sampleRate
        val keptMs = ranges.sumOf { it.endMs - it.startMs }

        assertTrue("should keep some speech", ranges.isNotEmpty())
        assertTrue(
            "should trim the 1.5s pause (kept $keptMs of $originalMs ms)",
            keptMs < originalMs - 800,
        )
        assertTrue("keeps speech from the start", ranges.first().startMs <= 150)
        assertTrue(
            "keeps speech to the end",
            ranges.last().endMs >= originalMs - 150,
        )
    }

    @Test
    fun `computeKeepRanges trims an asymmetric off-center pause`() {
        // Speech for 0.5s, a 2.0s pause (sitting near the front, not centered),
        // then 0.5s more speech.
        val sampleRate = 16000
        val audio = FloatArray((sampleRate * 3.0).toInt())
        for (i in audio.indices) {
            val t = i.toDouble() / sampleRate
            audio[i] = when {
                t < 0.5 -> 0.3f * sin(2 * Math.PI * 220 * t).toFloat()   // speech
                t < 2.5 -> 0.0005f * sin(2 * Math.PI * 50 * t).toFloat() // ~silence
                else -> 0.3f * sin(2 * Math.PI * 220 * t).toFloat()      // speech
            }
        }

        val ranges = AudioAnalyzer.computeKeepRanges(audio, sampleRate)
        val originalMs = audio.size.toLong() * 1000 / sampleRate
        val keptMs = ranges.sumOf { it.endMs - it.startMs }

        assertWellFormed(ranges, originalMs)
        assertTrue("keeps speech at both ends", ranges.size >= 2)
        assertTrue(
            "trims most of the 2.0s pause (kept $keptMs of $originalMs ms)",
            keptMs < originalMs - 1200,
        )
        assertTrue("keeps the leading speech", ranges.first().startMs <= 150)
        assertTrue("keeps the trailing speech", ranges.last().endMs >= originalMs - 150)
    }

    // --- Edge cases on the pure interval primitives -------------------------

    @Test
    fun `all-silence clip collapses to a minimal leading stub`() {
        // One silence run covering the whole 5s clip (touches both edges).
        val durSec = 5.0
        val durMs = 5000L
        val cuts = AudioAnalyzer.toCuts(listOf(Span(0.0, durSec)), durSec)
        val keeps = AudioAnalyzer.complement(AudioAnalyzer.mergeSpans(cuts), durSec, durMs)

        assertWellFormed(keeps, durMs)
        assertEquals("a whole-silent clip keeps exactly one stub", 1, keeps.size)
        val keptMs = keeps.sumOf { it.endMs - it.startMs }
        assertTrue("the stub is short (kept $keptMs ms)", keptMs in 1L..200L)
        assertEquals("the stub starts at 0", 0L, keeps.first().startMs)
    }

    @Test
    fun `a pause spanning both edges never yields a keep inside a cut`() {
        // A tiny speech island leaves a leading trim and a trailing trim that
        // overlap, plus a short internal collapse nested inside the leading cut.
        // The old complement let the cursor run backward and emitted a phantom
        // keep inside a cut; merge + the monotonic guard must prevent that.
        val durSec = 6.0
        val durMs = 6000L
        val cuts = listOf(
            Span(0.0, 3.0),   // leading trim
            Span(1.0, 1.5),   // internal collapse nested inside the leading trim
            Span(2.0, 5.8),   // trailing trim, overlaps the leading one
        )
        val merged = AudioAnalyzer.mergeSpans(cuts)
        assertEquals("overlapping/nested cuts merge into one", 1, merged.size)

        val keeps = AudioAnalyzer.complement(merged, durSec, durMs)
        assertWellFormed(keeps, durMs)
        for (k in keeps) {
            for (c in merged) {
                val inside = k.startMs >= (c.a * 1000).toLong() && k.endMs <= (c.b * 1000).toLong()
                assertTrue("keep $k must not fall inside cut $c", !inside)
            }
        }
    }

    @Test
    fun `two adjacent collapsible pauses merge into one cut`() {
        // Two long silence runs that abut (no speech between). Each is collapsed,
        // and where the resulting cuts touch they must merge rather than leaving
        // a zero-width sliver between them.
        val durSec = 4.0
        val cuts = AudioAnalyzer.toCuts(
            listOf(Span(1.0, 2.0), Span(2.0, 3.0)),
            durSec,
        )
        assertEquals("two collapsible pauses make two cuts", 2, cuts.size)

        // A directly adjacent pair must collapse to a single span.
        val merged = AudioAnalyzer.mergeSpans(listOf(Span(1.0, 2.0), Span(2.0, 3.0)))
        assertEquals("adjacent cuts merge", 1, merged.size)
        assertEquals(1.0, merged[0].a, 1e-9)
        assertEquals(3.0, merged[0].b, 1e-9)
    }

    @Test
    fun `computeKeepRanges on empty audio returns an empty list, never a zero-width range`() {
        // No samples at all → no duration → "no edit" (empty), not KeepRange(0,0).
        val ranges = AudioAnalyzer.computeKeepRanges(FloatArray(0), 16000)
        assertTrue("empty audio yields no keep-ranges", ranges.isEmpty())
    }

    @Test
    fun `computeKeepRanges on sub-millisecond audio returns an empty list`() {
        // A handful of samples rounds to 0 ms of duration; the result must be the
        // empty "no edit" list rather than a degenerate KeepRange(0, 0).
        val sampleRate = 16000
        val ranges = AudioAnalyzer.computeKeepRanges(FloatArray(5), sampleRate)
        assertEquals("rounds to 0 ms, so no keep-ranges", emptyList<KeepRange>(), ranges)
    }

    @Test
    fun `complement keeps the whole clip when there are no cuts`() {
        // No silence detected → no cuts → keep the whole clip as a single valid
        // positive-width range. This is the deterministic "nothing to trim" path
        // (asserting it through complement avoids depending on how Otsu classifies
        // a degenerate, near-uniform spectrum).
        val durMs = 2000L
        val keeps = AudioAnalyzer.complement(emptyList(), 2.0, durMs)
        assertWellFormed(keeps, durMs)
        assertEquals("no cuts → one whole-clip range", 1, keeps.size)
        assertEquals("keeps from the very start", 0L, keeps.first().startMs)
        assertEquals("keeps to the very end", durMs, keeps.last().endMs)
    }

    @Test
    fun `computeKeepRanges on a steady tone keeps well-formed ranges spanning the clip`() {
        // End-to-end smoke over the detector: a steady tone has no real dead air,
        // so whatever ranges come out must be well-formed and cover essentially
        // the whole clip (no zero-width/inverted ranges, no large unexplained
        // trims). Kept loose so it does not pin Otsu's exact threshold.
        val sampleRate = 16000
        val audio = FloatArray((sampleRate * 1.0).toInt()) { i ->
            0.3f * sin(2 * Math.PI * 220 * (i.toDouble() / sampleRate)).toFloat()
        }
        val ranges = AudioAnalyzer.computeKeepRanges(audio, sampleRate)
        val originalMs = audio.size.toLong() * 1000 / sampleRate
        assertWellFormed(ranges, originalMs)
        val keptMs = ranges.sumOf { it.endMs - it.startMs }
        assertTrue(
            "keeps essentially the whole tone (kept $keptMs of $originalMs ms)",
            keptMs >= originalMs - 200,
        )
    }

    @Test
    fun `computeKeepRanges rejects a non-positive sample rate`() {
        // Symmetric guard with detect(): division by sampleRate must not happen.
        try {
            AudioAnalyzer.computeKeepRanges(FloatArray(16000), 0)
            org.junit.Assert.fail("expected IllegalStateException for sampleRate <= 0")
        } catch (_: IllegalStateException) {
            // expected
        }
    }

    @Test
    fun `complement returns an empty list when there is no duration`() {
        // durMs <= 0 must short-circuit to empty, never the KeepRange(0, 0) that
        // the all-cut fallback would otherwise produce.
        assertTrue(
            "no duration → no keep-ranges",
            AudioAnalyzer.complement(emptyList(), 0.0, 0L).isEmpty(),
        )
    }

    @Test
    fun `complement keeps the whole clip when cuts cover everything but duration is positive`() {
        // A cut covering the entire clip would leave no complement, so the
        // fallback keeps the whole clip — a valid positive-width range, not (0,0).
        val durMs = 4000L
        val keeps = AudioAnalyzer.complement(listOf(Span(0.0, 4.0)), 4.0, durMs)
        assertWellFormed(keeps, durMs)
        assertEquals("fallback is a single whole-clip range", 1, keeps.size)
        assertEquals(0L, keeps.first().startMs)
        assertEquals(durMs, keeps.first().endMs)
    }

    @Test
    fun `an asymmetric pause is collapsed within its own run`() {
        // The collapse window is centered and clamped to the run, so the cut can
        // never spill past the silence it came from.
        val durSec = 5.0
        val run = Span(1.0, 3.0) // 2.0s internal pause
        val cuts = AudioAnalyzer.toCuts(listOf(run), durSec)

        assertEquals("one internal pause yields one cut", 1, cuts.size)
        val cut = cuts[0]
        assertTrue("cut stays within the run", cut.a >= run.a - 1e-9 && cut.b <= run.b + 1e-9)
        val collapsedTo = (run.b - run.a) - (cut.b - cut.a)
        assertEquals("collapses to ~COLLAPSE_TO_S", 0.20, collapsedTo, 0.02)
    }

    /** Assert keep-ranges are ordered, positive-width, disjoint, and in-bounds. */
    private fun assertWellFormed(keeps: List<KeepRange>, durMs: Long) {
        assertTrue("at least one keep", keeps.isNotEmpty())
        var prevEnd = 0L
        for (k in keeps) {
            assertTrue("range $k has positive width", k.endMs > k.startMs)
            assertTrue("range $k starts in bounds", k.startMs >= 0)
            assertTrue("range $k ends in bounds", k.endMs <= durMs)
            assertTrue("range $k starts at/after the previous end ($prevEnd)", k.startMs >= prevEnd)
            prevEnd = k.endMs
        }
    }
}
