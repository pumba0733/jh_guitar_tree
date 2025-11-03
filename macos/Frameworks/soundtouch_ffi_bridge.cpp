#include <cstdint>
#include "SoundTouch.h"
using namespace soundtouch;

#if defined(_WIN32) || defined(_WIN64)
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif

EXPORT void *st_create() { return new SoundTouch(); }
EXPORT void st_destroy(void *ptr) { delete (SoundTouch *)ptr; }
EXPORT void st_dispose(void *ptr) { st_destroy(ptr); }

EXPORT void st_set_tempo(void *ptr, float tempo)
{
    ((SoundTouch *)ptr)->setTempo(tempo);
}

EXPORT void st_set_pitch_semitones(void *ptr, float semis)
{
    ((SoundTouch *)ptr)->setPitchSemiTones(semis);
}

EXPORT void st_set_rate(void *ptr, float rate)
{
    ((SoundTouch *)ptr)->setRate(rate);
}

// ✅ 추가: 샘플레이트 / 채널
EXPORT void st_set_sample_rate(void *ptr, int sampleRate)
{
    ((SoundTouch *)ptr)->setSampleRate(sampleRate);
}

EXPORT void st_set_channels(void *ptr, int channels)
{
    ((SoundTouch *)ptr)->setChannels(channels);
}

EXPORT void st_put_samples(void *ptr, const float *samples, uint32_t numSamples)
{
    ((SoundTouch *)ptr)->putSamples(samples, numSamples);
}

EXPORT uint32_t st_receive_samples(void *ptr, float *outBuffer, uint32_t maxSamples)
{
    return ((SoundTouch *)ptr)->receiveSamples(outBuffer, maxSamples);
}

EXPORT uint32_t st_num_samples(void *ptr)
{
    return ((SoundTouch *)ptr)->numSamples();
}

EXPORT void st_flush(void *ptr)
{
    ((SoundTouch *)ptr)->flush();
}

extern "C"
{
    void *SoundTouch_createInstance() { return st_create(); }
    void SoundTouch_destroyInstance(void *p) { st_destroy(p); }
    void SoundTouch_setTempoChange(void *p, float v) { st_set_tempo(p, v); }
    void SoundTouch_setRateChange(void *p, float v) { st_set_rate(p, v); }
    void SoundTouch_setPitchSemiTones(void *p, float v) { st_set_pitch_semitones(p, v); }
    void SoundTouch_putSamples(void *p, const float *s, uint32_t n) { st_put_samples(p, s, n); }
    uint32_t SoundTouch_receiveSamples(void *p, float *o, uint32_t n) { return st_receive_samples(p, o, n); }
    uint32_t SoundTouch_numSamples(void *p) { return st_num_samples(p); }
    void SoundTouch_flush(void *p) { st_flush(p); }
    void SoundTouch_clear(void *p) { ((SoundTouch *)p)->clear(); }
}
