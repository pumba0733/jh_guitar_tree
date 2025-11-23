// ─────────────────────────────────────────────────────────────
//  SmartMediaPlayer FFI - SoundTouch + miniaudio (Final, A안)
//  완전체 안정화 버전
// ─────────────────────────────────────────────────────────────

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
#include <cmath>

using namespace soundtouch;

// ─────────────────────────────
// 🔧 전역 상태
// ─────────────────────────────
static ma_device gDevice;
static SoundTouch gST;

static std::mutex gMutex;
static std::atomic<bool> gRunning{false};

// 재생 시간 = 실제 출력된 샘플 수
static std::atomic<uint64_t> gProcessedSamples{0};

// 출력 볼륨
static float gVolume = 1.0f;

// 파형·RMS 계산용 마지막 출력 버퍼
static constexpr int BUF_FRAMES = 4096;
static std::vector<float> gLastBuffer(BUF_FRAMES * 2);

// ─────────────────────────────
// ⚙️ SoundTouch 파라미터 즉시 반영
// ─────────────────────────────
static inline void applySoundTouchParams_unsafe()
{
    // 변조 파라미터 변경 후 이전 큐 폐기
    // → 다음 receiveSamples부터 즉시 새 변조 적용됨
    gST.clear();
    gST.flush();
}

// ─────────────────────────────
// 🎧 Audio Callback
// ─────────────────────────────
void data_callback(ma_device *pDevice, void *pOutput, const void *, ma_uint32 frameCount)
{
    float *out = (float *)pOutput;

    int received = 0;

    {
        std::lock_guard<std::mutex> lock(gMutex);

        // 변조 샘플 받아오기
        received = gST.receiveSamples(out, frameCount);

        // tempo/pitch 변경 직후 buffer 비는 문제 대응
        if (received == 0)
        {
            gST.flush();
            received = gST.receiveSamples(out, frameCount);
        }

        // 🔥 최근 출력 버퍼 저장
        if (received > 0)
        {
            int copyFrames = std::min<int>(received, BUF_FRAMES);
            memcpy(gLastBuffer.data(), out, copyFrames * 2 * sizeof(float));
        }
        else
        {
            memset(gLastBuffer.data(), 0, BUF_FRAMES * 2 * sizeof(float));
        }
    }

    // underflow → 무음 패딩 + timeline 증가
    if (received <= 0)
    {
        memset(out, 0, frameCount * 2 * sizeof(float));
        gProcessedSamples += frameCount;
        return;
    }

    // 🔊 Volume
    int total = received * 2;
    for (int i = 0; i < total; ++i)
        out[i] *= gVolume;

    // 부족한 프레임 무음 패딩
    if (received < (int)frameCount)
    {
        int padStart = received * 2;
        int padSamples = (frameCount - received) * 2;
        memset(out + padStart, 0, padSamples * sizeof(float));
    }

    // 타임라인 증가
    gProcessedSamples += received;
}

// ─────────────────────────────
// ⚙️ 내부 초기화
// ─────────────────────────────
void initSoundTouch()
{
    std::lock_guard<std::mutex> lock(gMutex);

    gST.setSampleRate(44100);
    gST.setChannels(2);

    gST.setTempo(1.0f);
    gST.setPitchSemiTones(0.0f);

    gVolume = 1.0f;
    gProcessedSamples.store(0);

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
        printf("[AudioChain] ❌ Device init failed\n");
        return false;
    }

    printf("[AudioChain] ✅ Device ready (44100Hz/2ch)\n");
    return true;
}

// ─────────────────────────────
// 🧩 FFI Entry Points
// ─────────────────────────────
extern "C"
{

    void st_create()
    {
        if (gRunning.load())
            return;

        initSoundTouch();

        if (!initAudioDevice())
            return;

        if (ma_device_start(&gDevice) == MA_SUCCESS)
        {
            gRunning.store(true);
            printf("[FFI] ▶ Playback started\n");
        }
    }

    void st_dispose()
    {
        if (!gRunning.load())
            return;

        gRunning.store(false);
        ma_device_uninit(&gDevice);

        {
            std::lock_guard<std::mutex> lock(gMutex);
            gST.clear();
        }

        printf("[FFI] ⏹ Disposed\n");
    }

    void st_feed_pcm(float *data, int frames)
    {
        if (!gRunning.load())
            return;

        std::lock_guard<std::mutex> lock(gMutex);
        gST.putSamples(data, frames);
    }

    void st_set_tempo(float t)
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.setTempo(t);
        applySoundTouchParams_unsafe();
        printf("[ST] tempo=%.3f\n", t);
    }

    void st_set_pitch_semitones(float semi)
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.setPitchSemiTones(semi);
        applySoundTouchParams_unsafe();
        printf("[ST] pitch=%.3f\n", semi);
    }

    void st_set_volume(float v)
    {
        gVolume = v;
        printf("[ST] volume=%.3f\n", v);
    }

    double st_get_playback_time()
    {
        return (double)gProcessedSamples.load() / 44100.0;
    }

    // 🔥 최근 출력 버퍼 전달
    void st_copyLastBuffer(float *dst, int maxFrames)
    {
        int frames = std::min<int>(maxFrames, BUF_FRAMES);
        memcpy(dst, gLastBuffer.data(), frames * 2 * sizeof(float));
    }

    // 🔥 RMS
    double st_getRmsLevel()
    {
        double sum = 0.0;
        int N = BUF_FRAMES * 2;

        for (int i = 0; i < N; ++i)
        {
            float v = gLastBuffer[i];
            sum += (double)v * v;
        }
        return sqrt(sum / N);
    }

} // extern "C"
