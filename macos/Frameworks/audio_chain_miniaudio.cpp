#define MINIAUDIO_IMPLEMENTATION
#define MA_ENABLE_COREAUDIO

#include "../ThirdParty/miniaudio/miniaudio.h"
#include "../ThirdParty/soundtouch/include/SoundTouch.h"

#include <thread>
#include <atomic>
#include <vector>
#include <mutex>
#include <chrono>
#include <cstdio>
#include <cstring>

using namespace soundtouch;

// ─────────────────────────────
// 🔧 전역 상태
// ─────────────────────────────
static ma_device gDevice;
static SoundTouch gST;
static std::thread gDecodeThread;
static std::mutex gMutex;
static std::atomic<bool> gRunning{false};
static float gVolume = 1.0f;

static constexpr int BUF_FRAMES = 4096;
static std::vector<float> gDecodeBuffer(BUF_FRAMES * 2);
static std::vector<float> gOutputBuffer(BUF_FRAMES * 2);

// ─────────────────────────────
// 🎧 Audio Callback
// ─────────────────────────────
void data_callback(ma_device *pDevice, void *pOutput, const void *, ma_uint32 frameCount)
{
    int received = 0;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        received = gST.receiveSamples(gOutputBuffer.data(), frameCount);
    }

    if (received <= 0)
    {
        memset(pOutput, 0, frameCount * pDevice->playback.channels * sizeof(float));
        return;
    }

    for (int i = 0; i < received * pDevice->playback.channels; ++i)
        gOutputBuffer[i] *= gVolume;

    memcpy(pOutput, gOutputBuffer.data(), received * pDevice->playback.channels * sizeof(float));
}

// ─────────────────────────────
// ⚙️ 내부 함수들
// ─────────────────────────────
void initSoundTouch()
{
    std::lock_guard<std::mutex> lock(gMutex);
    gST.setSampleRate(44100);
    gST.setChannels(2);
    gST.setTempo(1.0f);
    gST.setPitchSemiTones(0);
    printf("[SoundTouch] ✅ Initialized\n");
}

bool initAudioDevice()
{
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = 44100;
    config.dataCallback = data_callback;

    if (ma_device_init(nullptr, &config, &gDevice) != MA_SUCCESS)
    {
        printf("[AudioChain] ❌ Failed to init device\n");
        return false;
    }
    printf("[AudioChain] ✅ Device ready: 44100 Hz, 2 ch\n");
    return true;
}

void startPlayback(const char *path)
{
    printf("[AudioChain] ▶️ startPlayback(%s)\n", path);
    if (gRunning.load())
        return;

    initSoundTouch();
    if (initAudioDevice())
    {
        ma_device_start(&gDevice);
        gRunning = true;
        printf("[AudioChain] ▶️ Playback started\n");
    }
}

void stopPlayback()
{
    if (!gRunning.load())
        return;
    gRunning = false;

    ma_device_uninit(&gDevice);
    printf("[AudioChain] ⏹️ Playback stopped\n");
}

void setTempo(double t)
{
    std::lock_guard<std::mutex> lock(gMutex);
    gST.setTempo((float)t);
    printf("[ST] tempo=%.3f\n", t);
}

void setPitch(double s)
{
    std::lock_guard<std::mutex> lock(gMutex);
    gST.setPitchSemiTones((float)s);
    printf("[ST] pitch=%.3f\n", s);
}

void setVolume(float v)
{
    gVolume = v;
    printf("[ST] volume=%.3f\n", v);
}

// ─────────────────────────────
// 🟢 PCM Feed (from Dart → SoundTouch)
// ─────────────────────────────
extern "C" void st_feed_pcm(float *data, int frames)
{
    if (!gRunning.load())
        return;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.putSamples(data, frames);
    }
}

// ─────────────────────────────
// 🔗 FFI Entry Points
// ─────────────────────────────
extern "C"
{
    void st_create()
    {
        printf("[FFI] st_create()\n");
        initSoundTouch();
        if (initAudioDevice())
        {
            ma_device_start(&gDevice);
            gRunning = true;
            printf("[AudioChain] ▶️ Playback started\n");
        }
    }

    void st_dispose()
    {
        stopPlayback();
        printf("[FFI] st_dispose()\n");
    }

    void st_audio_start_with_file(const char *path)
    {
        startPlayback(path);
        printf("[FFI] ▶️ Audio start (file=%s)\n", path);
    }

    void st_audio_stop()
    {
        stopPlayback();
        printf("[FFI] ⏹️ Audio stop\n");
    }

    void st_set_tempo(double t)
    {
        setTempo(t);
    }

    void st_set_pitch_semitones(double s)
    {
        setPitch(s);
    }

    void st_set_volume(float v)
    {
        setVolume(v);
    }
}
