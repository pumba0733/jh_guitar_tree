#ifndef FFTW_BRIDGE_H
#define FFTW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

    // returns 0 on success; non-zero on error
    // left/right: float32 PCM [-1..+1], separate buffers (right can be NULL for mono)
    // out arrays: row-major [frames * bands], caller allocates
    // out_frames: set to computed frame count
    __attribute__((visibility("default"))) int fftw_analyze_bands_f32(
        const float *left,
        const float *right,
        int32_t samples,
        int32_t sample_rate,
        int32_t fft_size,
        int32_t hop_size,
        int32_t bands,
        int32_t a_weighting,
        float *out_left,
        float *out_right,
        int32_t *out_frames);

#ifdef __cplusplus
}
#endif

#endif /* FFTW_BRIDGE_H */
