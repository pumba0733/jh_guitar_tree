#import "SoundTouchBridge.h"
#import "../ThirdParty/SoundTouch/SoundTouch.h"
using namespace soundtouch;

void *STCreate(void) { return new SoundTouch(); }
void STDispose(void *handle) { delete static_cast<SoundTouch *>(handle); }

void STSetTempo(void *handle, float tempo) {
  auto *st = static_cast<SoundTouch *>(handle);
  st->setTempo(tempo);
}

void STSetPitchSemiTones(void *handle, float semitones) {
  auto *st = static_cast<SoundTouch *>(handle);
  st->setPitchSemiTones(semitones);
}

void STFlush(void *handle) {
  auto *st = static_cast<SoundTouch *>(handle);
  st->flush(); // ← 반환 없음
}
