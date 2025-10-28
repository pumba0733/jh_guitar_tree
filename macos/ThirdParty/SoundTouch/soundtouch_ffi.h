#ifndef soundtouch_ffi_bridge_h
#define soundtouch_ffi_bridge_h

#ifdef __cplusplus
extern "C" {
#endif

void *st_create(void);
void st_dispose(void *handle);
void st_set_tempo(void *handle, float tempo);
void st_set_pitch_semitones(void *handle, float semi);
int st_flush(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* soundtouch_ffi_bridge_h */
