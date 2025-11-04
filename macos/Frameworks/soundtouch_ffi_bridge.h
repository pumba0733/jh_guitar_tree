#pragma once
#include <cstdint>

#if defined(_WIN32) || defined(_WIN64)
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif

EXPORT void *st_create();
EXPORT void st_destroy(void *ptr);
EXPORT void st_set_tempo(void *ptr, float tempo);
EXPORT void st_set_pitch_semitones(void *ptr, float semis);
EXPORT void st_set_rate(void *ptr, float rate);
EXPORT void st_set_sample_rate(void *ptr, int sr);
EXPORT void st_set_channels(void *ptr, int ch);
EXPORT void st_put_samples(void *ptr, const float *samples, uint32_t n);
EXPORT uint32_t st_receive_samples(void *ptr, float *out, uint32_t n);
EXPORT void st_play_samples(void *ptr, const float *samples, uint32_t n);
EXPORT void st_audio_stop();
