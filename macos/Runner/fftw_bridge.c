#include "fftw_bridge.h"
#include <fftw3.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// -------- window / weighting --------
static void hann_window(float *w, int n)
{
    for (int i = 0; i < n; i++)
    {
        w[i] = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * (float)i / (float)(n - 1)));
    }
}

// coarse A-weighting (approx, SR~44.1/48k)
static float a_weight_gain(float f)
{
    // IEC-ish approximation
    const float f2 = f * f;
    const float r1 = f2 + 20.6f * 20.6f;
    const float r2 = f2 + 12200.0f * 12200.0f;
    const float r3 = (f2 + 107.7f * 107.7f) * (f2 + 737.9f * 737.9f);
    const float ra = (12200.0f * 12200.0f * f2 * f2) / (r1 * sqrtf(r3) * r2 + 1e-20f);
    const float a_db = 2.0f + 20.0f * log10f(ra + 1e-20f);
    // dB -> linear
    return powf(10.0f, a_db / 20.0f);
}

static void make_log_bands(int sr, int nfft, int bands, int *bin_st, int *bin_ed)
{
    const int nyq = sr / 2;
    const float fmin = 50.0f;
    const float fmax = (float)nyq;
    const float logmin = logf(fmin);
    const float logmax = logf(fmax);

    for (int b = 0; b < bands; b++)
    {
        const float t0 = (float)b / (float)bands;
        const float t1 = (float)(b + 1) / (float)bands;
        const float f0 = expf(logmin + (logmax - logmin) * t0);
        const float f1 = expf(logmin + (logmax - logmin) * t1);
        int k0 = (int)floorf(f0 * (float)nfft / (float)sr);
        int k1 = (int)ceilf(f1 * (float)nfft / (float)sr);
        if (k0 < 1)
            k0 = 1;
        if (k1 > nfft / 2)
            k1 = nfft / 2;
        if (k1 <= k0)
            k1 = k0 + 1;
        bin_st[b] = k0;
        bin_ed[b] = k1;
    }
}

// -------- main analyze --------
__attribute__((used, visibility("default"))) int fftw_analyze_bands_f32(
    const float *left,
    const float *right, // can be NULL (mono)
    int32_t samples,
    int32_t sample_rate,
    int32_t fft_size,
    int32_t hop_size,
    int32_t bands,
    int32_t a_weighting,
    float *out_left,
    float *out_right,
    int32_t *out_frames)
{
    if (!left || samples <= 0 || sample_rate <= 0 ||
        fft_size <= 0 || hop_size <= 0 || bands <= 0 ||
        !out_left || !out_right || !out_frames)
    {
        return 1;
    }
    if (samples < fft_size)
    {
        *out_frames = 0;
        return 2;
    }

    const int frames = 1 + (samples - fft_size) / hop_size;
    *out_frames = frames;

    // window
    float *win = (float *)malloc(sizeof(float) * (size_t)fft_size);
    if (!win)
        return 3;
    hann_window(win, fft_size);

    // fft buffers & plan
    float *inbuf = (float *)fftwf_malloc(sizeof(float) * (size_t)fft_size);
    if (!inbuf)
    {
        free(win);
        return 4;
    }
    fftwf_complex *spec = (fftwf_complex *)fftwf_malloc(sizeof(fftwf_complex) * (size_t)(fft_size / 2 + 1));
    if (!spec)
    {
        fftwf_free(inbuf);
        free(win);
        return 5;
    }

    fftwf_plan plan = fftwf_plan_dft_r2c_1d(fft_size, inbuf, spec, FFTW_ESTIMATE);
    if (!plan)
    {
        fftwf_free(spec);
        fftwf_free(inbuf);
        free(win);
        return 6;
    }

    // band bins
    int *b0 = (int *)malloc(sizeof(int) * (size_t)bands);
    int *b1 = (int *)malloc(sizeof(int) * (size_t)bands);
    if (!b0 || !b1)
    {
        if (b0)
            free(b0);
        if (b1)
            free(b1);
        fftwf_destroy_plan(plan);
        fftwf_free(spec);
        fftwf_free(inbuf);
        free(win);
        return 7;
    }
    make_log_bands(sample_rate, fft_size, bands, b0, b1);

    // mapping constants
    const float DB_MIN = -80.0f;
    const float DB_MAX = 0.0f;
    const float DB_SPAN = (DB_MAX - DB_MIN);

    for (int ch = 0; ch < 2; ch++)
    {
        const float *x = (ch == 0) ? left : (right ? right : left); // mono safe
        float *out = (ch == 0) ? out_left : out_right;

        int idx = 0;
        for (int f = 0; f < frames; f++)
        {
            const int off = f * hop_size;

            // windowed frame
            for (int i = 0; i < fft_size; i++)
            {
                inbuf[i] = x[off + i] * win[i];
            }
            fftwf_execute(plan);

            // bands: RMS(power) → dB → [0..1]
            for (int b = 0; b < bands; b++)
            {
                double pow_sum = 0.0;
                int bins = 0;
                for (int k = b0[b]; k <= b1[b]; k++)
                {
                    const float re = spec[k][0];
                    const float im = spec[k][1];
                    const float mag2 = (re * re + im * im); // power
                    float g = 1.0f;
                    if (a_weighting)
                    {
                        const float freq = (float)k * (float)sample_rate / (float)fft_size;
                        g = a_weight_gain(freq);
                    }
                    pow_sum += (double)mag2 * (double)g * (double)g;
                    bins++;
                }
                if (bins < 1)
                    bins = 1;
                const double mean_power = pow_sum / (double)bins;
                const double rms = sqrt(fmax(mean_power, 1e-24));

                // dBFS-ish (relative)
                const double db = 10.0 * log10(fmax(rms, 1e-24));
                double norm = (db - (double)DB_MIN) / (double)DB_SPAN; // map [-80..0] → [0..1]
                if (norm < 0.0)
                    norm = 0.0;
                if (norm > 1.0)
                    norm = 1.0;

                out[idx++] = (float)norm;
            }
        }
    }

    // cleanup
    free(b0);
    free(b1);
    fftwf_destroy_plan(plan);
    fftwf_free(spec);
    fftwf_free(inbuf);
    free(win);

    return 0;
}

// Dead strip 방지용 더미(옵션)
static void *_keep_fftw(void) { return (void *)&fftw_analyze_bands_f32; }
