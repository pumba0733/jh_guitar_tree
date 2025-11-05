// v3.39.3 — SoundTouch + AudioQueue loop complete
// Author: GPT-5 (JHGuitarTree Core)

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <cstdio>
#include <thread>
#include <mutex>
#include "SoundTouch.h"
using namespace soundtouch;

struct STContext
{
    SoundTouch *soundTouch;
    AudioQueueRef queue;
    AudioStreamBasicDescription format;
    UInt32 bufferSize;
    int channels;
};

static std::mutex gMutex;
static STContext *gCtx = nullptr;

// -------- Callbacks --------
static void AQCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer)
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (!gCtx || !gCtx->soundTouch)
        return;

    float *out = reinterpret_cast<float *>(inBuffer->mAudioData);
    int maxFrames = inBuffer->mAudioDataBytesCapacity / (sizeof(float) * gCtx->channels);
    int frames = gCtx->soundTouch->receiveSamples(out, maxFrames);
    if (frames > 0)
    {
        printf("[🟢 AQ feed] pushed %d frames\n", frames);
        inBuffer->mAudioDataByteSize = frames * sizeof(float) * gCtx->channels;
    }
    else
    {
        memset(out, 0, inBuffer->mAudioDataBytesCapacity);
        inBuffer->mAudioDataByteSize = inBuffer->mAudioDataBytesCapacity;
        printf("[🟢 AQ feed] silence\n");
    }
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nullptr);
}

// -------- API --------
extern "C"
{

    void *st_create()
    {
        gCtx = new STContext();
        gCtx->soundTouch = new SoundTouch();
        gCtx->soundTouch->setSampleRate(44100);
        gCtx->soundTouch->setChannels(2);
        gCtx->channels = 2;
        printf("[FFI] ✅ st_create (44100Hz, 2ch)\n");
        return gCtx;
    }

    void st_dispose(void *ptr)
    {
        if (!ptr)
            return;
        auto *ctx = (STContext *)ptr;
        if (ctx->queue)
            AudioQueueStop(ctx->queue, true);
        delete ctx->soundTouch;
        delete ctx;
        gCtx = nullptr;
    }

    void st_set_sample_rate(void *ptr, int rate)
    {
        if (!ptr)
            return;
        ((STContext *)ptr)->soundTouch->setSampleRate(rate);
    }

    void st_set_channels(void *ptr, int ch)
    {
        if (!ptr)
            return;
        ((STContext *)ptr)->soundTouch->setChannels(ch);
        ((STContext *)ptr)->channels = ch;
    }

    void st_set_tempo(void *ptr, double tempo)
    {
        if (!ptr)
            return;
        ((STContext *)ptr)->soundTouch->setTempo(tempo);
    }

    void st_set_pitch_semitones(void *ptr, double semi)
    {
        if (!ptr)
            return;
        ((STContext *)ptr)->soundTouch->setPitchSemiTones(semi);
    }

    void st_put_samples(void *ptr, const float *samples, int count)
    {
        if (!ptr)
            return;
        auto *ctx = (STContext *)ptr;
        ctx->soundTouch->putSamples(samples, count);
        printf("[🔵 feed] received %d samples\n", count);

        float tmp[4096];
        int got = ctx->soundTouch->receiveSamples(tmp, 4096);
        if (got > 0)
            printf("[🟣 receive] %d ready\n", got);
    }

    int st_receive_samples(void *ptr, float *out, int maxCount)
    {
        if (!ptr)
            return 0;
        auto *ctx = (STContext *)ptr;
        int frames = ctx->soundTouch->receiveSamples(out, maxCount);
        if (frames > 0)
            printf("[🟣 receive] %d pulled\n", frames);
        return frames;
    }

    void st_audio_start(void *ptr)
    {
        auto *ctx = (STContext *)ptr;
        ctx->format.mSampleRate = 44100;
        ctx->format.mFormatID = kAudioFormatLinearPCM;
        ctx->format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        ctx->format.mChannelsPerFrame = ctx->channels;
        ctx->format.mBitsPerChannel = 32;
        ctx->format.mBytesPerFrame = 4 * ctx->channels;
        ctx->format.mFramesPerPacket = 1;
        ctx->format.mBytesPerPacket = ctx->format.mBytesPerFrame * ctx->format.mFramesPerPacket;
        ctx->bufferSize = 4096 * ctx->format.mBytesPerFrame;

        AudioQueueNewOutput(&ctx->format, AQCallback, ctx, nullptr, nullptr, 0, &ctx->queue);
        for (int i = 0; i < 3; i++)
        {
            AudioQueueBufferRef buffer;
            AudioQueueAllocateBuffer(ctx->queue, ctx->bufferSize, &buffer);
            AQCallback(ctx, ctx->queue, buffer);
        }
        AudioQueueStart(ctx->queue, nullptr);
        printf("[FFI] ✅ AudioQueue started\n");
    }

    void st_audio_stop()
    {
        if (gCtx && gCtx->queue)
        {
            AudioQueueStop(gCtx->queue, true);
            printf("[FFI] 🛑 AudioQueue stopped\n");
        }
    }

    void st_enqueue_to_audioqueue(float *data, int samples)
    {
        if (!gCtx || !gCtx->queue)
            return;

        AudioQueueBufferRef buffer;
        AudioQueueAllocateBuffer(gCtx->queue,
                                 samples * sizeof(float) * gCtx->channels,
                                 &buffer);

        memcpy(buffer->mAudioData, data, samples * sizeof(float) * gCtx->channels);
        buffer->mAudioDataByteSize = samples * sizeof(float) * gCtx->channels;

        AudioQueueEnqueueBuffer(gCtx->queue, buffer, 0, nullptr);
        printf("[🟢 PCM→AudioQueue] pushed %d samples\n", samples);
    }

} // extern "C"
