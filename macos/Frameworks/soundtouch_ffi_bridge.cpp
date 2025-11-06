// macos/Frameworks/soundtouch_ffi_bridge.cpp
// v3.39.9 — Final Integration (SoundTouch + AudioQueue + FFI)
// Author: GPT-5 (JHGuitarTree Core)
// Purpose: Connect SoundTouch PCM pipeline → AudioQueue for realtime playback

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include "../ThirdParty/soundtouch/include/SoundTouch.h"
#include <mutex>
#include <thread>
#include <atomic>
#include <vector>
#include <cmath>
#include <cstdio>

using namespace soundtouch;

// === Global ===
static SoundTouch g_st;
static AudioQueueRef g_queue = nullptr;
static std::mutex g_mutex;
static std::atomic<bool> g_running(false);
static float g_masterGain = 1.0f;

static const int kSampleRate = 44100;
static const int kChannels = 2;
static const int kBufferFrames = 4096;
static const int kNumBuffers = 3;

// ✅ 전방선언 (이거 꼭 필요)
extern "C" void AQCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer);

// === FFI EXPORT MACRO ===
extern "C"
{

    // ===== Life Cycle =====
    void *st_create()
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        printf("[FFI] st_create()\n");
        g_st.setSampleRate(kSampleRate);
        g_st.setChannels(kChannels);
        g_st.setTempo(1.0f);
        g_st.setPitchSemiTones(0.0f);
        g_st.clear();
        g_masterGain = 1.0f;
        return &g_st;
    }

    void st_dispose(void *ctx)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        printf("[FFI] st_dispose()\n");
        g_st.clear();
    }

    // ===== Basic Setters =====
    void st_set_sample_rate(void *ctx, int sr)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_st.setSampleRate(sr);
    }
    void st_set_channels(void *ctx, int ch)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_st.setChannels(ch);
    }
    void st_set_tempo(void *ctx, double tempo)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_st.setTempo(tempo);
        printf("[FFI] tempo=%.3f\n", tempo);
    }
    void st_set_pitch_semitones(void *ctx, double semi)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_st.setPitchSemiTones(semi);
        printf("[FFI] pitch=%.3f\n", semi);
    }
    void st_set_volume(void *ctx, float gain)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_masterGain = gain;
        printf("[FFI] volume=%.3f\n", gain);
    }

    // ===== Feed / Receive =====
    void st_put_samples(void *ctx, const float *samples, int n)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!samples || n <= 0)
            return;
        g_st.putSamples(samples, n / kChannels);
    }

    int st_receive_samples(void *ctx, float *outBuf, int maxSamples)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!outBuf)
            return 0;
        return g_st.receiveSamples(outBuf, maxSamples / kChannels);
    }

    // ===== AudioQueue Bridge =====
    static void InitQueueIfNeeded()
    {
        if (g_queue != nullptr)
            return;

        AudioStreamBasicDescription fmt = {0};
        fmt.mSampleRate = kSampleRate;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags =
            kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        fmt.mBytesPerPacket = sizeof(float) * kChannels;
        fmt.mFramesPerPacket = 1;
        fmt.mBytesPerFrame = sizeof(float) * kChannels;
        fmt.mChannelsPerFrame = kChannels;
        fmt.mBitsPerChannel = sizeof(float) * 8;

        OSStatus err = AudioQueueNewOutput(
            &fmt, AQCallback, nullptr, nullptr, nullptr, 0, &g_queue);
        if (err)
        {
            printf("[AQ] ❌ AudioQueueNewOutput failed: %d\n", (int)err);
            return;
        }

        for (int i = 0; i < kNumBuffers; i++)
        {
            AudioQueueBufferRef buf;
            AudioQueueAllocateBuffer(g_queue, kBufferFrames * sizeof(float) * kChannels, &buf);
            buf->mAudioDataByteSize = kBufferFrames * sizeof(float) * kChannels;
            memset(buf->mAudioData, 0, buf->mAudioDataByteSize);
            AudioQueueEnqueueBuffer(g_queue, buf, 0, nullptr);
        }
        printf("[AQ] ✅ Initialized %d buffers\n", kNumBuffers);
    }

    void AQCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_running)
            return;

        float *dst = reinterpret_cast<float *>(buffer->mAudioData);
        int wanted = kBufferFrames * kChannels;
        int got = g_st.receiveSamples(dst, kBufferFrames);
        if (got <= 0)
        {
            memset(dst, 0, buffer->mAudioDataByteSize);
            got = kBufferFrames;
        }

        // Apply master gain
        for (int i = 0; i < got * kChannels; ++i)
            dst[i] *= g_masterGain;

        buffer->mAudioDataByteSize = got * sizeof(float) * kChannels;
        AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);

        printf("[AQ] 🟢 feed %d frames (gain=%.2f)\n", got, g_masterGain);
    }

    void st_audio_start(void *ctx)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        InitQueueIfNeeded();
        if (!g_queue)
            return;
        g_running = true;
        AudioQueueStart(g_queue, nullptr);
        printf("[FFI] ▶️ AudioQueue started\n");
    }

    void st_audio_stop()
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_queue)
        {
            AudioQueueStop(g_queue, true);
            AudioQueueDispose(g_queue, true);
            g_queue = nullptr;
        }
        g_running = false;
        printf("[FFI] ⏹️ AudioQueue stopped\n");
    }

    void st_enqueue_to_audioqueue(const float *samples, int count)
    {
        if (!samples || count <= 0)
            return;
        if (!g_queue)
            return;

        AudioQueueBufferRef buf;
        AudioQueueAllocateBuffer(g_queue, count * sizeof(float), &buf);
        buf->mAudioDataByteSize = count * sizeof(float);
        memcpy(buf->mAudioData, samples, buf->mAudioDataByteSize);
        AudioQueueEnqueueBuffer(g_queue, buf, 0, nullptr);

        printf("[PCM] 📤 enqueue_to_audioqueue %d samples\n", count);
    }

} // extern "C"
