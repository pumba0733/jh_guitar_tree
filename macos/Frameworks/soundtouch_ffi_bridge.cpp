// macos/Frameworks/soundtouch_ffi_bridge.cpp
// v3.36.0 — JH_GuitarTree / SmartMediaPlayer 통합 버전
// Exported symbols: st_create, st_dispose, st_set_tempo, st_set_pitch_semitones,
//                   st_set_sample_rate, st_set_channels, st_put_samples,
//                   st_receive_samples, st_audio_start, st_audio_stop.

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include "../ThirdParty/soundtouch/include/SoundTouch.h"
#include <mutex>
#include <thread>
#include <atomic>
#include <chrono>
#include <vector>

using namespace soundtouch;

static std::mutex gMutex;
static std::atomic<bool> gIsRunning{false};
static std::thread gAudioThread;
static AudioQueueRef gQueue = nullptr;

static SoundTouch *gST = nullptr;
static const int kSampleRateDefault = 44100;
static const int kChannelsDefault = 2;

// ===============================
// 🔧 SoundTouch 객체 관리
// ===============================
extern "C" void *st_create()
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gST)
        delete gST;
    gST = new SoundTouch();
    gST->setSampleRate(kSampleRateDefault);
    gST->setChannels(kChannelsDefault);
    gST->setTempo(1.0f);
    gST->setPitchSemiTones(0.0f);
    return (void *)gST;
}

extern "C" void st_dispose(void *handle)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gST)
    {
        delete gST;
        gST = nullptr;
    }
}

// ===============================
// ⚙️ 파라미터 설정
// ===============================
extern "C" void st_set_sample_rate(void *handle, int sr)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gST)
        gST->setSampleRate(sr);
}

extern "C" void st_set_channels(void *handle, int ch)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gST)
        gST->setChannels(ch);
}

extern "C" void st_set_tempo(void *handle, double tempo)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gST)
        gST->setTempo((float)tempo);
}

extern "C" void st_set_pitch_semitones(void *handle, double semi)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gST)
        gST->setPitchSemiTones((float)semi);
}

// ===============================
// 🎵 PCM 입출력
// ===============================
extern "C" void st_put_samples(void *handle, const float *input, int numSamples)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gST && input && numSamples > 0)
        gST->putSamples(input, numSamples);
}

extern "C" int st_receive_samples(void *handle, float *output, int maxSamples)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gST || !output || maxSamples <= 0)
        return 0;
    return gST->receiveSamples(output, maxSamples);
}

// ===============================
// ▶️ AudioQueue 재생
// ===============================
static const int kSampleRate = 44100;
static const int kChannels = 2;

void AQCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gIsRunning.load() || !gST)
        return;

    const int maxSamples = inBuffer->mAudioDataBytesCapacity / sizeof(float);
    float *buffer = (float *)inBuffer->mAudioData;
    int received = gST->receiveSamples(buffer, maxSamples / kChannels);
    inBuffer->mAudioDataByteSize = received * kChannels * sizeof(float);

    if (received > 0)
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nullptr);
}

extern "C" void st_audio_start(void *handle)
{
    if (gIsRunning.load())
        return;
    if (!handle)
        handle = gST;
    if (!handle)
        return;

    gIsRunning.store(true);

    gAudioThread = std::thread([]
                               {
        AudioStreamBasicDescription fmt = {0};
        fmt.mSampleRate = kSampleRate;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        fmt.mBytesPerFrame = kChannels * sizeof(float);
        fmt.mFramesPerPacket = 1;
        fmt.mBytesPerPacket = fmt.mBytesPerFrame;
        fmt.mChannelsPerFrame = kChannels;
        fmt.mBitsPerChannel = 32;

        OSStatus status = AudioQueueNewOutput(&fmt, AQCallback, nullptr, nullptr, nullptr, 0, &gQueue);
        if (status != noErr)
        {
            fprintf(stderr, "[SoundTouchFFI] ❌ AudioQueueNewOutput failed: %d\n", (int)status);
            gIsRunning.store(false);
            return;
        }

        // 🎚️ 버퍼 사전 할당
        const int numBuffers = 3;
        for (int i = 0; i < numBuffers; ++i)
        {
            AudioQueueBufferRef buffer;
            AudioQueueAllocateBuffer(gQueue, 4096 * sizeof(float) * kChannels, &buffer);
            AQCallback(nullptr, gQueue, buffer);
        }

        AudioQueueStart(gQueue, nullptr);
        fprintf(stderr, "[SoundTouchFFI] ✅ AudioQueue started (thread: %p)\n", (void*)pthread_self());

        while (gIsRunning.load())
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }

        AudioQueueStop(gQueue, true);
        AudioQueueDispose(gQueue, true);
        gQueue = nullptr;
        fprintf(stderr, "[SoundTouchFFI] 🔚 AudioQueue stopped (thread exit)\n"); });

    gAudioThread.detach();
}

extern "C" void st_audio_stop()
{
    gIsRunning.store(false);
}
