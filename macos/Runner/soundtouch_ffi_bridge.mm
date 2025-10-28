#import "soundtouch_ffi_bridge.h"
#import "../ThirdParty/SoundTouch/SoundTouch.h"
using namespace soundtouch;

void *st_create(void) { return new SoundTouch(); }
void st_dispose(void *handle) { delete static_cast<SoundTouch *>(handle); }

void st_set_tempo(void *handle, float tempo) {
  auto *st = static_cast<SoundTouch *>(handle);
  st->setTempo(tempo);
}

void st_set_pitch_semitones(void *handle, float semitones) {
  auto *st = static_cast<SoundTouch *>(handle);
  st->setPitchSemiTones(semitones);
}

void st_flush(void *handle) {
  auto *st = static_cast<SoundTouch *>(handle);
  st->flush(); // ← 반환 없음
}
