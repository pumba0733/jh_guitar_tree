#include <cstdint>
#include <cstring>
#include <AudioToolbox/AudioToolbox.h>
#include "SoundTouch.h"

using namespace soundtouch;

#if defined(_WIN32) || defined(_WIN64)
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif

// ---------------------- 전역 상태 ----------------------
static AudioQueueRef g_audioQueue = nullptr;
static AudioStreamBasicDescription g_format;
static AudioQueueBufferRef g_buffers[3];
static int g_currentBuffer = 0;
static bool g_started = false;

// ---------------------- SoundTouch 래퍼 ----------------------
EXPORT void *st_create() { return new SoundTouch(); }
EXPORT void st_destroy(void *ptr) { delete (SoundTouch *)ptr; }
EXPORT void st_dispose(void *ptr) { st_destroy(ptr); }

EXPORT void st_set_tempo(void *ptr, float tempo) { ((SoundTouch *)ptr)->setTempo(tempo); }
EXPORT void st_set_pitch_semitones(void *ptr, float semis) { ((SoundTouch *)ptr)->setPitchSemiTones(semis); }
EXPORT void st_set_rate(void *ptr, float rate) { ((SoundTouch *)ptr)->setRate(rate); }
EXPORT void st_set_sample_rate(void *ptr, int sr) { ((SoundTouch *)ptr)->setSampleRate(sr); }
EXPORT void st_set_channels(void *ptr, int ch) { ((SoundTouch *)ptr)->setChannels(ch); }

EXPORT void st_put_samples(void *ptr, const float *samples, uint32_t n) { ((SoundTouch *)ptr)->putSamples(samples, n); }
EXPORT uint32_t st_receive_samples(void *ptr, float *out, uint32_t n) { return ((SoundTouch *)ptr)->receiveSamples(out, n); }
EXPORT uint32_t st_num_samples(void *ptr) { return ((SoundTouch *)ptr)->numSamples(); }
EXPORT void st_flush(void *ptr) { ((SoundTouch *)ptr)->flush(); }

// ---------------------- AudioQueue 초기화 ----------------------
static void ensureAudioQueue(int sampleRate, int channels)
{
    if (g_audioQueue)
        return;
    memset(&g_format, 0, sizeof(g_format));
    g_format.mSampleRate = sampleRate;
    g_format.mFormatID = kAudioFormatLinearPCM;
    g_format.mFormatFlags = kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    g_format.mChannelsPerFrame = channels;
    g_format.mBitsPerChannel = 32;
    g_format.mBytesPerFrame = channels * sizeof(float);
    g_format.mBytesPerPacket = g_format.mBytesPerFrame;
    g_format.mFramesPerPacket = 1;
    AudioQueueNewOutput(&g_format, nullptr, nullptr, nullptr, nullptr, 0, &g_audioQueue);
    for (int i = 0; i < 3; ++i)
        AudioQueueAllocateBuffer(g_audioQueue, 4096 * sizeof(float) * channels, &g_buffers[i]);
    AudioQueueStart(g_audioQueue, nullptr);
    g_started = true;
}

// ---------------------- 실시간 재생 ----------------------
EXPORT void st_play_samples(void *ptr, const float *samples, uint32_t numSamples)
{
    if (!samples || !numSamples)
        return;
    SoundTouch *st = (SoundTouch *)ptr;
    const int sampleRate = 44100, channels = 2;
    ensureAudioQueue(sampleRate, channels);
    st->putSamples(samples, numSamples);
    float outBuf[4096 * 2];
    uint32_t received = 0;
    while ((received = st->receiveSamples(outBuf, 4096)) > 0)
    {
        AudioQueueBufferRef buffer = g_buffers[g_currentBuffer];
        g_currentBuffer = (g_currentBuffer + 1) % 3;
        uint32_t bytes = received * sizeof(float) * channels;
        if (bytes > buffer->mAudioDataBytesCapacity)
            bytes = buffer->mAudioDataBytesCapacity;
        memcpy(buffer->mAudioData, outBuf, bytes);
        buffer->mAudioDataByteSize = bytes;
        AudioQueueEnqueueBuffer(g_audioQueue, buffer, 0, nullptr);
    }
}

// ---------------------- 종료 ----------------------
EXPORT void st_audio_stop()
{
    if (g_audioQueue)
    {
        AudioQueueStop(g_audioQueue, true);
        for (int i = 0; i < 3; ++i)
            if (g_buffers[i])
                AudioQueueFreeBuffer(g_audioQueue, g_buffers[i]);
        AudioQueueDispose(g_audioQueue, true);
        g_audioQueue = nullptr;
        g_started = false;
    }
}

// ---------------------- C 링크 심볼 ----------------------
extern "C"
{
    void *SoundTouch_createInstance() { return st_create(); }
    void SoundTouch_destroyInstance(void *p) { st_destroy(p); }
    void SoundTouch_setTempoChange(void *p, float v) { st_set_tempo(p, v); }
    void SoundTouch_setRateChange(void *p, float v) { st_set_rate(p, v); }
    void SoundTouch_setPitchSemiTones(void *p, float v) { st_set_pitch_semitones(p, v); }
    void SoundTouch_playSamples(void *p, const float *s, uint32_t n) { st_play_samples(p, s, n); }
    void SoundTouch_audioStop() { st_audio_stop(); }
}
