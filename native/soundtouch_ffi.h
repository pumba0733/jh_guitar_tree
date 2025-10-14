// native/soundtouch_ffi.h
// v1.90.0 | C API for Dart FFI (SoundTouch wrapper)

#pragma once
#ifdef __cplusplus
extern "C"
{
#endif

#ifdef _WIN32
#define ST_API __declspec(dllexport)
#else
#define ST_API __attribute__((visibility("default")))
#endif

  typedef void *st_handle;

  ST_API st_handle st_create(void);
  ST_API void st_dispose(st_handle h);

  ST_API void st_set_samplerate(st_handle h, int sample_rate);
  ST_API void st_set_channels(st_handle h, int channels);
  ST_API void st_set_tempo(st_handle h, double tempo);
  ST_API void st_set_pitch_semitones(st_handle h, double semi);
  ST_API void st_set_rate(st_handle h, double rate);

  ST_API int st_put_samples(st_handle h, const float *samples, int frames);
  ST_API int st_receive_samples(st_handle h, float *out_samples, int max_frames);
  ST_API int st_flush(st_handle h);
  ST_API void st_clear(st_handle h);
  ST_API int st_get_latency(st_handle h);

#ifdef __cplusplus
}
#endif
