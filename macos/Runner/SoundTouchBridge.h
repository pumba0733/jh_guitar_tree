#pragma once
#ifdef __cplusplus
extern "C" {
#endif

void *STCreate(void);
void STDispose(void *handle);
void STSetTempo(void *handle, float tempo);
void STSetPitchSemiTones(void *handle, float semitones);
void STFlush(void *handle); // ← int → void 로 통일

#ifdef __cplusplus
}
#endif
