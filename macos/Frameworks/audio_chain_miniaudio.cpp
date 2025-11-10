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

using namespace soundtouch;

// ======== 전역 상태 ========
static ma_device gDevice;
static ma_decoder gDecoder;
static SoundTouch gST;
static std::thread gThread;
static std::mutex gMutex;
static std::atomic<bool> gRunning{false};
static float gVolume = 1.0f;
static std::string gCurrentFile;

// ======== 내부 버퍼 ========
static constexpr int BUF_FRAMES = 4096;
static std::vector<float> gDecodeBuffer(BUF_FRAMES * 2);
static std::vector<float> gOutputBuffer(BUF_FRAMES * 2);

// ======== 디코더 스레드 ========
void decodeLoop()
{
    printf("[DecodeLoop] ▶️ Start decoding: %s\n", gCurrentFile.c_str());
    while (gRunning.load())
    {
        ma_uint64 framesRead = 0;
        ma_result r = ma_decoder_read_pcm_frames(&gDecoder, gDecodeBuffer.data(), BUF_FRAMES, &framesRead);
        if (r != MA_SUCCESS || framesRead == 0)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        // 🔹 SoundTouch로 입력
        {
            std::lock_guard<std::mutex> lock(gMutex);
            gST.putSamples(gDecodeBuffer.data(), (uint)framesRead);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    printf("[DecodeLoop] ⏹️ End\n");
}

// ======== 오디오 콜백 (SoundTouch → 출력) ========
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

// ======== 초기화 ========
bool initDecoder(const char *path)
{
    if (ma_decoder_init_file(path, nullptr, &gDecoder) != MA_SUCCESS)
    {
        printf("[AudioChain] ❌ Failed to open file: %s\n", path);
        return false;
    }
    gCurrentFile = path;
    printf("[AudioChain] ✅ Decoder ready (%s)\n", path);
    return true;
}

void initAudioDevice()
{
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = 44100;
    config.dataCallback = data_callback;

    if (ma_device_init(nullptr, &config, &gDevice) != MA_SUCCESS)
    {
        printf("[AudioChain] ❌ Failed to init device\n");
        return;
    }
    printf("[AudioChain] ✅ Audio device initialized\n");
}

void initSoundTouch()
{
    std::lock_guard<std::mutex> lock(gMutex);
    gST.setSampleRate(44100);
    gST.setChannels(2);
    gST.setTempo(1.0);
    gST.setPitchSemiTones(0);
    printf("[SoundTouch] ✅ Initialized\n");
}

// ======== 재생 제어 ========
void startPlayback(const char *path)
{
    if (gRunning.load())
        return;
    if (!initDecoder(path))
        return;
    initSoundTouch();
    initAudioDevice();
    gRunning = true;
    ma_device_start(&gDevice);
    gThread = std::thread(decodeLoop);
    printf("[AudioChain] ▶️ Playback started\n");
}

void stopPlayback()
{
    if (!gRunning.load())
        return;
    gRunning = false;
    if (gThread.joinable())
        gThread.join();
    ma_device_uninit(&gDevice);
    ma_decoder_uninit(&gDecoder);
    printf("[AudioChain] ⏹️ Playback stopped\n");
}

// ======== 파라미터 제어 ========
void setTempo(double t)
{
    std::lock_guard<std::mutex> lock(gMutex);
    gST.setTempo(t);
    printf("[ST] tempo=%.3f\n", t);
}

void setPitch(double s)
{
    std::lock_guard<std::mutex> lock(gMutex);
    gST.setPitchSemiTones(s);
    printf("[ST] pitch=%.3f\n", s);
}

void setVolume(float v)
{
    gVolume = v;
    printf("[ST] volume=%.3f\n", v);
}
