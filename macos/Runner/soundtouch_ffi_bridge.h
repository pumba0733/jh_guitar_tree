#pragma once
#ifdef __cplusplus
extern "C" {
#endif

void *st_create(void);
void st_dispose(void *handle);
void st_set_tempo(void *handle, float tempo);
void st_set_pitch_semitones(void *handle, float semitones);
void st_flush(void *handle); // ← int → void 로 통일

#ifdef __cplusplus
}
#endif
