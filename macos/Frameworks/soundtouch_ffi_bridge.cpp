#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include "../ThirdParty/soundtouch/include/SoundTouch.h"
#include <atomic>
#include <mutex>
#include <thread>
#include <chrono>
#include <cstdio>
#include <cstring>

using namespace soundtouch;

static SoundTouch g_st;
static AudioQueueRef g_queue = nullptr;
static std::mutex g_mutex;
static std::atomic<bool> g_running(false);
static float g_gain = 1.0f;

const int kSR = 44100;
const int kCH = 2;
const int kFrames = 4096;

extern "C"
{

    void *st_create()
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_st.setSampleRate(kSR);
        g_st.setChannels(kCH);
        g_st.setTempo(1.0f);
        g_st.setPitchSemiTones(0.0f);
        g_gain = 1.0f;
        printf("[FFI] st_create()\n");
        return &g_st;
    }

    void st_dispose(void *ctx)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_st.clear();
        printf("[FFI] st_dispose()\n");
    }

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

    void st_set_tempo(void *ctx, double t)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_st.setTempo(t);
    }

    void st_set_pitch_semitones(void *ctx, double p)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_st.setPitchSemiTones(p);
    }

    void st_set_volume(void *ctx, float g)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_gain = g;
    }

    void st_put_samples(void *ctx, const float *s, int n)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!s || n <= 0)
            return;
        g_st.putSamples(s, n / kCH);
    }

    int st_receive_samples(void *ctx, float *out, int n)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!out || n <= 0)
            return 0;
        int got = g_st.receiveSamples(out, n / kCH);
        return got;
    }

    static void AQCallback(void *ud, AudioQueueRef q, AudioQueueBufferRef b)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_running)
            return;
        float *dst = reinterpret_cast<float *>(b->mAudioData);
        int got = g_st.receiveSamples(dst, kFrames);
        if (got <= 0)
            memset(dst, 0, kFrames * sizeof(float) * kCH);
        for (int i = 0; i < got * kCH; ++i)
            dst[i] *= g_gain;
        b->mAudioDataByteSize = got * sizeof(float) * kCH;
        AudioQueueEnqueueBuffer(q, b, 0, nullptr);
    }

    void st_audio_start(void *ctx)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_queue)
        {
            AudioStreamBasicDescription fmt = {0};
            fmt.mSampleRate = kSR;
            fmt.mFormatID = kAudioFormatLinearPCM;
            fmt.mFormatFlags = kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            fmt.mBytesPerFrame = sizeof(float) * kCH;
            fmt.mChannelsPerFrame = kCH;
            fmt.mBitsPerChannel = 32;
            AudioQueueNewOutput(&fmt, AQCallback, nullptr, nullptr, nullptr, 0, &g_queue);
            for (int i = 0; i < 3; ++i)
            {
                AudioQueueBufferRef buf;
                AudioQueueAllocateBuffer(g_queue, kFrames * sizeof(float) * kCH, &buf);
                AudioQueueEnqueueBuffer(g_queue, buf, 0, nullptr);
            }
        }
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
        printf("[FFI] ⏹️ stopped\n");
    }

    void st_enqueue_to_audioqueue(const float *s, int n)
    {
        if (!s || n <= 0 || !g_queue)
            return;
        AudioQueueBufferRef b;
        AudioQueueAllocateBuffer(g_queue, n * sizeof(float), &b);
        b->mAudioDataByteSize = n * sizeof(float);
        memcpy(b->mAudioData, s, b->mAudioDataByteSize);
        AudioQueueEnqueueBuffer(g_queue, b, 0, nullptr);
    }
}
