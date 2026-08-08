/*
 * Standalone spike: exercise the exact aubio call sequence the NIF will use,
 * against a synthesized 120 BPM click track, with no BEAM involved.
 *
 *   make verify
 *
 * Exits non-zero when the analysis misses its thresholds, so it is a real gate
 * rather than a wall of numbers. The thresholds match the ExUnit anchor test
 * (test/s2l/aubio_test.exs) on purpose: if this passes and the NIF test fails,
 * the problem is provably the Elixir/C glue and not the DSP.
 */

#include <aubio.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define SAMPLE_RATE 44100
#define BUF_SIZE 1024
#define HOP_SIZE 512
#define N_BANDS 16
#define BPM 120.0
#define CLICKS 20

/* Deterministic noise, so a failure is reproducible. Same LCG as the Elixir
 * click-track generator, so both harnesses analyze an identical signal. */
static unsigned int rng_state = 12345u;

static float noise(void)
{
    rng_state = (unsigned int)((rng_state * 1103515245u + 12345u) & 0x7fffffffu);
    return (float)rng_state / 1073741824.0f - 1.0f;
}

/* One click: a noise transient over a 60 Hz thump, decaying in ~20 ms. Broadband
 * enough for the onset detector, low-heavy enough to read as a kick. */
static void write_click(float *out, unsigned int len)
{
    for (unsigned int i = 0; i < len; i++) {
        double t = (double)i / SAMPLE_RATE;
        double env = exp(-t * 50.0);
        double body = sin(2.0 * M_PI * 60.0 * t);
        out[i] = (float)(0.9 * env * (0.5 * body + 0.5 * noise()));
    }
}

static float *synth_click_track(unsigned int *total_len)
{
    unsigned int period = (unsigned int)(SAMPLE_RATE * 60.0 / BPM);
    unsigned int click_len = 2048;
    unsigned int len = period * CLICKS;
    float *pcm = calloc(len, sizeof(float));

    if (!pcm) {
        return NULL;
    }

    for (unsigned int c = 0; c < CLICKS; c++) {
        write_click(pcm + (size_t)c * period, click_len);
    }

    *total_len = len;
    return pcm;
}

int main(void)
{
    unsigned int len = 0;
    float *pcm = synth_click_track(&len);

    if (!pcm) {
        fprintf(stderr, "verify: out of memory\n");
        return 1;
    }

    aubio_tempo_t *tempo = new_aubio_tempo("default", BUF_SIZE, HOP_SIZE, SAMPLE_RATE);
    aubio_onset_t *onset = new_aubio_onset("hfc", BUF_SIZE, HOP_SIZE, SAMPLE_RATE);
    aubio_pvoc_t *pvoc = new_aubio_pvoc(BUF_SIZE, HOP_SIZE);
    aubio_filterbank_t *filterbank = new_aubio_filterbank(N_BANDS, BUF_SIZE);

    if (!tempo || !onset || !pvoc || !filterbank) {
        fprintf(stderr, "verify: failed to construct aubio objects\n");
        return 1;
    }

    if (aubio_filterbank_set_mel_coeffs(filterbank, (smpl_t)SAMPLE_RATE, 0.0f,
                                        (smpl_t)SAMPLE_RATE / 2.0f) != 0) {
        fprintf(stderr, "verify: failed to set mel coefficients\n");
        return 1;
    }

    fvec_t *tempo_out = new_fvec(2);
    fvec_t *onset_out = new_fvec(2);
    fvec_t *bands = new_fvec(N_BANDS);
    cvec_t *spectrum = new_cvec(BUF_SIZE);

    unsigned int onsets = 0, beats = 0, late_beats = 0, negative_bands = 0;
    unsigned int hops = len / HOP_SIZE;
    /* The tempo tracker needs a few seconds of evidence before it locks, so
     * beats are only counted after that. Onsets are expected immediately. */
    unsigned int lock_hop = (unsigned int)(4.0 * SAMPLE_RATE / HOP_SIZE);
    double peak_band_energy = 0.0;

    for (unsigned int h = 0; h < hops; h++) {
        /* The zero-copy pattern the NIF relies on: a stack fvec_t pointing
         * straight at the caller's samples. aubio only reads its input. */
        fvec_t in = {.length = HOP_SIZE, .data = pcm + (size_t)h * HOP_SIZE};

        aubio_tempo_do(tempo, &in, tempo_out);
        aubio_onset_do(onset, &in, onset_out);
        aubio_pvoc_do(pvoc, &in, spectrum);
        aubio_filterbank_do(filterbank, spectrum, bands);

        if (tempo_out->data[0] != 0) {
            beats++;
            if (h >= lock_hop) {
                late_beats++;
            }
        }

        if (onset_out->data[0] != 0) {
            onsets++;
        }

        for (unsigned int b = 0; b < N_BANDS; b++) {
            if (bands->data[b] < 0.0f) {
                negative_bands++;
            }
            if (bands->data[b] > peak_band_energy) {
                peak_band_energy = bands->data[b];
            }
        }
    }

    double bpm = aubio_tempo_get_bpm(tempo);
    double confidence = aubio_tempo_get_confidence(tempo);

    printf("hops=%u onsets=%u beats=%u late_beats=%u\n", hops, onsets, beats, late_beats);
    printf("bpm=%.2f confidence=%.3f peak_band=%.4f negative_bands=%u\n", bpm, confidence,
           peak_band_energy, negative_bands);

    int failures = 0;

    if (fabs(bpm - BPM) > 3.0) {
        fprintf(stderr, "FAIL: bpm %.2f is not within 3 of %.1f\n", bpm, BPM);
        failures++;
    }

    if (onsets < 15) {
        fprintf(stderr, "FAIL: only %u onsets, expected at least 15 of %d clicks\n", onsets,
                CLICKS);
        failures++;
    }

    if (late_beats < 5) {
        fprintf(stderr, "FAIL: only %u beats after lock, expected at least 5\n", late_beats);
        failures++;
    }

    if (negative_bands > 0) {
        fprintf(stderr, "FAIL: %u negative filterbank values\n", negative_bands);
        failures++;
    }

    if (peak_band_energy <= 0.0) {
        fprintf(stderr, "FAIL: filterbank never saw energy\n");
        failures++;
    }

    del_aubio_tempo(tempo);
    del_aubio_onset(onset);
    del_aubio_pvoc(pvoc);
    del_aubio_filterbank(filterbank);
    del_fvec(tempo_out);
    del_fvec(onset_out);
    del_fvec(bands);
    del_cvec(spectrum);
    free(pcm);
    aubio_cleanup();

    if (failures) {
        printf("verify: %d check(s) failed\n", failures);
        return 1;
    }

    printf("verify: ok\n");
    return 0;
}
