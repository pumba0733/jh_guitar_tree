// ─────────────────────────────────────────────────────────────
//  SmartMediaPlayer FFI - FFmpeg + SoundTouch + miniaudio
//  v3.8-FF — STEP 3C-01 StableBuffer (Full Version)
//
//  목표:
//    - FFmpeg → SoundTouch → StableRingBuffer → miniaudio
//    - miniaudio 콜백은 StableRingBuffer.pop()만 사용
//    - SoT = 실제 디바이스로 출력된 프레임 수 (underflow 시 증가 금지)
//
//  구조:
//    FFmpeg 디코더 스레드:
//       - FFmpeg 디코드 → Swr로 변환
//       - gST.putSamples()
//       - gST.receiveSamples()로 변조 샘플을 꺼내
//         StableBuffer.push()로 링버퍼에 공급
//
//    miniaudio.data_callback:
//       - StableBuffer.pop()로 출력 샘플 획득
//       - 부족분은 무음 패딩 (SoT에는 포함 안 됨)
//       - 볼륨 적용 후 디바이스로 출력
//
//  특징:
//    - 디코더 스레드는 gPaused를 보고 "정지 상태면 디코딩 쉬기"
//    - StableBuffer는 중앙 재생 버퍼 (drop 없음, push 시 block 정책)
//    - seek 시 ST/StableBuffer/gLastBuffer/SoT 모두 정합 맞춰 초기화
// ─────────────────────────────────────────────────────────────

#define MINIAUDIO_IMPLEMENTATION
#define MA_ENABLE_COREAUDIO

#include "../ThirdParty/miniaudio/miniaudio.h"
#include "../ThirdParty/soundtouch/include/SoundTouch.h"

extern "C"
{
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
}

#include <thread>
#include <atomic>
#include <vector>
#include <mutex>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <algorithm>

// ─────────────────────────────
// 네임스페이스
// ─────────────────────────────
using namespace soundtouch;

// ─────────────────────────────
// 상수
// ─────────────────────────────
static constexpr int SAMPLE_RATE = 44100;
static constexpr int CHANNELS = 2;
static constexpr int BUF_FRAMES = 4096;         // RMS / last buffer
static constexpr int STABLE_CAP_FRAMES = 16384; // StableBuffer 용량 (프레임 단위)

// SoundTouch → StableBuffer로 옮길 때 사용할 청크 크기
static constexpr int ST_DRAIN_CHUNK_FRAMES = 1024;

// 기본 파라미터
static constexpr float DEFAULT_TEMPO = 1.0f;
static constexpr float DEFAULT_PITCH = 0.0f; // semitones
static constexpr float DEFAULT_VOL = 1.0f;

// ─────────────────────────────
// 로깅
// ─────────────────────────────
static inline void logLine(const char *tag, const char *msg)
{
    std::printf("[%s] %s\n", tag, msg);
}

// ─────────────────────────────
// StableBuffer — 재생용 링버퍼 (프레임 단위)
//  - FFmpeg+SoundTouch가 push (producer)
//  - miniaudio 콜백이 pop (consumer)
//  - drop 없이, push 시 공간 없으면 block (짧은 sleep 재시도)
// ─────────────────────────────
class StableBuffer
{
public:
    StableBuffer()
    {
        buffer_.resize(STABLE_CAP_FRAMES * CHANNELS, 0.0f);
        clear();
    }

    void clear()
    {
        std::lock_guard<std::mutex> lock(mu_);
        head_ = 0;
        tail_ = 0;
        count_ = 0;
        std::fill(buffer_.begin(), buffer_.end(), 0.0f);
    }

    // frames 단위 push
    //  - 가능한 만큼만 쓰고, 실제 쓴 프레임 수를 리턴
    int push(const float *src, int frames)
    {
        if (!src || frames <= 0)
            return 0;

        std::lock_guard<std::mutex> lock(mu_);

        int freeFrames = STABLE_CAP_FRAMES - count_;
        if (freeFrames <= 0)
        {
            return 0; // 더 이상 쓸 공간 없음
        }

        int framesToWrite = std::min(frames, freeFrames);

        for (int f = 0; f < framesToWrite; ++f)
        {
            for (int c = 0; c < CHANNELS; ++c)
            {
                buffer_[head_ * CHANNELS + c] = src[f * CHANNELS + c];
            }
            head_ = (head_ + 1) % STABLE_CAP_FRAMES;
        }
        count_ += framesToWrite;
        return framesToWrite;
    }

    // frames 단위 pop
    //  - 실제 가져온 프레임 수 리턴
    int pop(float *dst, int maxFrames)
    {
        if (!dst || maxFrames <= 0)
            return 0;

        std::lock_guard<std::mutex> lock(mu_);

        if (count_ <= 0)
            return 0;

        int framesToRead = std::min(maxFrames, count_);
        for (int f = 0; f < framesToRead; ++f)
        {
            for (int c = 0; c < CHANNELS; ++c)
            {
                dst[f * CHANNELS + c] = buffer_[tail_ * CHANNELS + c];
            }
            tail_ = (tail_ + 1) % STABLE_CAP_FRAMES;
        }
        count_ -= framesToRead;
        return framesToRead;
    }

    int size() const
    {
        std::lock_guard<std::mutex> lock(mu_);
        return count_;
    }

    int capacity() const
    {
        return STABLE_CAP_FRAMES;
    }

private:
    std::vector<float> buffer_;
    int head_ = 0;
    int tail_ = 0;
    int count_ = 0;
    mutable std::mutex mu_;
};

// ─────────────────────────────
// 전역 상태
// ─────────────────────────────

// StableBuffer (재생용 중앙 링버퍼)
static StableBuffer gStable;

// SoundTouch
static SoundTouch gST;
static std::mutex gMutex; // SoundTouch + gLastBuffer 보호

// miniaudio
static ma_device gDevice{};
static std::atomic<bool> gDeviceStarted{false};

// 재생 시간 = 실제 출력된 샘플 수 (SoT)
static std::atomic<uint64_t> gProcessedSamples{0};

// 출력 볼륨
static std::atomic<float> gVolume{DEFAULT_VOL};

// 파형/RMS용 마지막 출력 버퍼
static std::vector<float> gLastBuffer(BUF_FRAMES *CHANNELS);

// FFmpeg 디코더
static std::once_flag gFFmpegInitOnce;
static AVFormatContext *gFmtCtx = nullptr;
static AVCodecContext *gCodecCtx = nullptr;
static SwrContext *gSwr = nullptr;
static int gAudioStreamIndex = -1;
static std::thread gDecodeThread;
static std::atomic<bool> gDecodeRunning{false};
static std::atomic<bool> gFileOpened{false};
static double gDurationMs = 0.0;

// 전체 엔진 상태
static std::atomic<bool> gEngineCreated{false};
static std::atomic<bool> gRunning{false};
static std::atomic<bool> gPaused{true}; // 기본 정지

// ─────────────────────────────
// 내부 유틸
// ─────────────────────────────

static inline void applySoundTouchParams_unsafe()
{
    // STEP 3C-01:
    //  - tempo/pitch 변경 시 큐를 강제로 비우지 않는다.
    //  - 실제 샘플 흐름은 DecodeThread → StableBuffer로 제한되어 있으므로
    //    큐 길이(StableBuffer.size + ST 내부 큐)가 과도하게 길어지지 않도록
    //    디코더 쪽에서 back-pressure를 거는 것으로 충분.
}

// FFmpeg 초기화 (once)
static void initFFmpegOnce()
{
    std::call_once(gFFmpegInitOnce, []()
                   {
        av_log_set_level(AV_LOG_ERROR);
        avformat_network_init();
        logLine("FFmpeg", "initialized"); });
}

// SoundTouch 초기화
static void initSoundTouch()
{
    std::lock_guard<std::mutex> lock(gMutex);

    gST.setSampleRate(SAMPLE_RATE);
    gST.setChannels(CHANNELS);

    gST.setTempo(DEFAULT_TEMPO);
    gST.setPitchSemiTones(DEFAULT_PITCH);

    gVolume.store(DEFAULT_VOL);
    gProcessedSamples.store(0);
    std::fill(gLastBuffer.begin(), gLastBuffer.end(), 0.0f);

    logLine("SoundTouch", "initialized");
}

// FFmpeg 파일 닫기
static void closeFileInternal()
{
    // 디코더 스레드 중지
    gDecodeRunning.store(false);
    if (gDecodeThread.joinable())
    {
        gDecodeThread.join();
    }

    // FFmpeg 컨텍스트 정리
    if (gSwr)
    {
        swr_free(&gSwr);
        gSwr = nullptr;
    }
    if (gCodecCtx)
    {
        avcodec_free_context(&gCodecCtx);
        gCodecCtx = nullptr;
    }
    if (gFmtCtx)
    {
        avformat_close_input(&gFmtCtx);
        gFmtCtx = nullptr;
    }

    gAudioStreamIndex = -1;
    gDurationMs = 0.0;
    gFileOpened.store(false);

    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.clear();
        gST.flush();
        std::fill(gLastBuffer.begin(), gLastBuffer.end(), 0.0f);
    }

    gStable.clear();
    gProcessedSamples.store(0);

    logLine("FFmpeg", "file closed");
}

// FFmpeg 파일 열기
static bool openFileInternal(const char *path)
{
    initFFmpegOnce();
    closeFileInternal(); // 기존 파일 있으면 정리

    if (!path)
    {
        logLine("FFmpeg", "openFileInternal: null path");
        return false;
    }

    if (avformat_open_input(&gFmtCtx, path, nullptr, nullptr) < 0)
    {
        logLine("FFmpeg", "open_input failed");
        return false;
    }
    if (avformat_find_stream_info(gFmtCtx, nullptr) < 0)
    {
        logLine("FFmpeg", "find_stream_info failed");
        avformat_close_input(&gFmtCtx);
        gFmtCtx = nullptr;
        return false;
    }

    int streamIndex = av_find_best_stream(gFmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (streamIndex < 0)
    {
        logLine("FFmpeg", "no audio stream");
        avformat_close_input(&gFmtCtx);
        gFmtCtx = nullptr;
        return false;
    }
    gAudioStreamIndex = streamIndex;
    AVStream *st = gFmtCtx->streams[gAudioStreamIndex];

    const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec)
    {
        logLine("FFmpeg", "decoder not found");
        avformat_close_input(&gFmtCtx);
        gFmtCtx = nullptr;
        return false;
    }

    gCodecCtx = avcodec_alloc_context3(dec);
    if (!gCodecCtx)
    {
        logLine("FFmpeg", "alloc_context failed");
        avformat_close_input(&gFmtCtx);
        gFmtCtx = nullptr;
        return false;
    }

    if (avcodec_parameters_to_context(gCodecCtx, st->codecpar) < 0)
    {
        logLine("FFmpeg", "parameters_to_context failed");
        avcodec_free_context(&gCodecCtx);
        avformat_close_input(&gFmtCtx);
        gCodecCtx = nullptr;
        gFmtCtx = nullptr;
        return false;
    }

    if (avcodec_open2(gCodecCtx, dec, nullptr) < 0)
    {
        logLine("FFmpeg", "avcodec_open2 failed");
        avcodec_free_context(&gCodecCtx);
        avformat_close_input(&gFmtCtx);
        gCodecCtx = nullptr;
        gFmtCtx = nullptr;
        return false;
    }

    // SwrContext 설정 (모든 입력 → 44100Hz / stereo / float)
    int64_t in_ch_layout = gCodecCtx->channel_layout;
    if (in_ch_layout == 0)
    {
        in_ch_layout = av_get_default_channel_layout(gCodecCtx->channels);
    }

    gSwr = swr_alloc_set_opts(
        nullptr,
        AV_CH_LAYOUT_STEREO,
        AV_SAMPLE_FMT_FLT,
        SAMPLE_RATE,
        in_ch_layout,
        gCodecCtx->sample_fmt,
        gCodecCtx->sample_rate,
        0,
        nullptr);

    if (!gSwr || swr_init(gSwr) < 0)
    {
        logLine("FFmpeg", "swr_init failed");
        if (gSwr)
        {
            swr_free(&gSwr);
            gSwr = nullptr;
        }
        avcodec_free_context(&gCodecCtx);
        avformat_close_input(&gFmtCtx);
        gCodecCtx = nullptr;
        gFmtCtx = nullptr;
        return false;
    }

    // duration 계산
    if (st->duration > 0 && st->time_base.num > 0)
    {
        gDurationMs = st->duration * av_q2d(st->time_base) * 1000.0;
    }
    else if (gFmtCtx->duration > 0)
    {
        gDurationMs = gFmtCtx->duration * 1000.0 / AV_TIME_BASE;
    }
    else
    {
        gDurationMs = 0.0;
    }

    gProcessedSamples.store(0);
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.clear();
        gST.flush();
        std::fill(gLastBuffer.begin(), gLastBuffer.end(), 0.0f);
    }

    gStable.clear();
    gFileOpened.store(true);

    logLine("FFmpeg", "file opened");
    return true;
}

// 디코더 쓰레드
//  - FFmpeg → Swr → SoundTouch.putSamples()
//  - SoundTouch.receiveSamples() → StableBuffer.push()
//  - gPaused == true면 디코딩 잠시 쉼 (출력은 콜백에서 무음 처리)
static void decodeThreadFunc()
{
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();

    const int MAX_DST_SAMPLES = 4096;
    std::vector<float> convBuffer(MAX_DST_SAMPLES * CHANNELS);

    // SoundTouch에서 StableBuffer로 옮길 임시 버퍼
    std::vector<float> stDrainBuffer(ST_DRAIN_CHUNK_FRAMES * CHANNELS);

    while (gDecodeRunning.load())
    {
        // 재생이 일시정지거나 파일이 없으면 잠시 쉼
        if (gPaused.load() || !gFileOpened.load())
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        if (!gFmtCtx || !gCodecCtx || !gSwr || gAudioStreamIndex < 0)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        int ret = av_read_frame(gFmtCtx, pkt);
        if (ret < 0)
        {
            // EOF 등: Loop OFF 가정, 잠시 쉼
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        if (pkt->stream_index != gAudioStreamIndex)
        {
            av_packet_unref(pkt);
            continue;
        }

        ret = avcodec_send_packet(gCodecCtx, pkt);
        av_packet_unref(pkt);
        if (ret < 0)
        {
            continue;
        }

        while (ret >= 0)
        {
            ret = avcodec_receive_frame(gCodecCtx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            {
                break;
            }
            if (ret < 0)
            {
                break;
            }

            uint8_t *outData[1] = {
                reinterpret_cast<uint8_t *>(convBuffer.data())};

            int outSamples = swr_convert(
                gSwr,
                outData,
                MAX_DST_SAMPLES,
                const_cast<const uint8_t **>(frame->data),
                frame->nb_samples);

            if (outSamples > 0)
            {
                // 1) 변환한 샘플을 SoundTouch 입력 큐에 넣기
                {
                    std::lock_guard<std::mutex> lock(gMutex);
                    gST.putSamples(convBuffer.data(), outSamples);
                }

                // 2) SoundTouch에서 변조된 샘플을 StableBuffer로 이동
                //    - block 정책: StableBuffer에 빈 공간이 없으면
                //      짧게 sleep 하면서 공간 생길 때까지 반복
                bool drainMore = true;
                while (drainMore && gDecodeRunning.load() && !gPaused.load())
                {
                    int received = 0;
                    {
                        std::lock_guard<std::mutex> lock(gMutex);
                        received = gST.receiveSamples(
                            stDrainBuffer.data(),
                            ST_DRAIN_CHUNK_FRAMES);
                    }

                    if (received <= 0)
                    {
                        // 현재 더 이상 꺼낼 샘플이 없음
                        drainMore = false;
                        break;
                    }

                    int remaining = received;
                    int offsetFrames = 0;

                    while (remaining > 0 && gDecodeRunning.load() && !gPaused.load())
                    {
                        int written = gStable.push(
                            stDrainBuffer.data() + offsetFrames * CHANNELS,
                            remaining);

                        if (written <= 0)
                        {
                            // StableBuffer가 가득 찼으므로 소비될 때까지 잠시 대기
                            std::this_thread::sleep_for(std::chrono::milliseconds(5));
                            continue;
                        }

                        remaining -= written;
                        offsetFrames += written;
                    }

                    // paused로 전환되거나 decodeRunning이 false가 되면
                    // 남은 샘플은 버려도 괜찮다 (seek/정지/종료 처리 중)
                }
            }
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
}

// miniaudio 콜백
//  - StableBuffer.pop() → 실제 출력
//  - underflow 시 SoT 증가 없이 무음 출력
static void data_callback(ma_device * /*pDevice*/, void *pOutput, const void * /*pInput*/, ma_uint32 frameCount)
{
    float *out = static_cast<float *>(pOutput);

    // 정지 상태 또는 파일 미열림 상태에서는 항상 무음 + SoT 증가 없음
    if (gPaused.load() || !gFileOpened.load())
    {
        std::memset(out, 0, frameCount * CHANNELS * sizeof(float));
        {
            std::lock_guard<std::mutex> lock(gMutex);
            std::fill(gLastBuffer.begin(), gLastBuffer.end(), 0.0f);
        }
        return;
    }

    // StableBuffer에서 샘플 꺼내기
    int received = gStable.pop(out, static_cast<int>(frameCount));

    // underflow → SoT 증가 없이 무음 출력
    if (received <= 0)
    {
        std::memset(out, 0, frameCount * CHANNELS * sizeof(float));
        {
            std::lock_guard<std::mutex> lock(gMutex);
            std::fill(gLastBuffer.begin(), gLastBuffer.end(), 0.0f);
        }
        return;
    }

    // 최근 출력 버퍼 업데이트
    {
        std::lock_guard<std::mutex> lock(gMutex);

        int copyFrames = std::min<int>(received, BUF_FRAMES);
        std::memcpy(
            gLastBuffer.data(),
            out,
            copyFrames * CHANNELS * sizeof(float));

        if (copyFrames < BUF_FRAMES)
        {
            std::memset(
                gLastBuffer.data() + copyFrames * CHANNELS,
                0,
                (BUF_FRAMES - copyFrames) * CHANNELS * sizeof(float));
        }
    }

    // 볼륨 적용 (유효 샘플에만)
    const float vol = gVolume.load();
    int totalValidSamples = received * CHANNELS;
    for (int i = 0; i < totalValidSamples; ++i)
    {
        out[i] *= vol;
    }

    // 부족분 무음 패딩 (SoT에는 포함 안 됨)
    if (received < static_cast<int>(frameCount))
    {
        int padStart = received * CHANNELS;
        int padSamples = static_cast<int>(frameCount) * CHANNELS - padStart;
        std::memset(out + padStart, 0, padSamples * sizeof(float));
    }

    // SoT: 실제 출력된 유효 프레임만 누적
    gProcessedSamples += static_cast<uint64_t>(received);
}

// miniaudio 초기화
static bool initAudioDevice()
{
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = CHANNELS;
    config.sampleRate = SAMPLE_RATE;
    config.dataCallback = data_callback;
    config.pUserData = nullptr;

    if (ma_device_init(nullptr, &config, &gDevice) != MA_SUCCESS)
    {
        logLine("AudioChain", "device init failed");
        return false;
    }

    logLine("AudioChain", "device ready (44100Hz/2ch)");
    return true;
}

// 내부 seek
static void seekInternal(double ms)
{
    if (!gFileOpened.load() || !gFmtCtx || !gCodecCtx || gAudioStreamIndex < 0)
    {
        logLine("FFmpeg", "seekInternal: no file");
        return;
    }

    logLine("FFmpeg", "seekInternal called");

    bool wasPaused = gPaused.load();
    gPaused.store(true);

    // 디코더 스레드 잠시 중단
    gDecodeRunning.store(false);
    if (gDecodeThread.joinable())
    {
        gDecodeThread.join();
    }

    AVStream *st = gFmtCtx->streams[gAudioStreamIndex];
    double sec = ms / 1000.0;
    int64_t ts = static_cast<int64_t>(sec / av_q2d(st->time_base));

    if (av_seek_frame(gFmtCtx, gAudioStreamIndex, ts, AVSEEK_FLAG_BACKWARD) < 0)
    {
        logLine("FFmpeg", "av_seek_frame failed");
    }

    avcodec_flush_buffers(gCodecCtx);
    if (gSwr)
    {
        swr_convert(gSwr, nullptr, 0, nullptr, 0);
    }

    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.clear();
        gST.flush();
        std::fill(gLastBuffer.begin(), gLastBuffer.end(), 0.0f);
    }

    gStable.clear();

    // SoT를 타겟 위치로 재설정
    uint64_t targetSamples = static_cast<uint64_t>((ms / 1000.0) * SAMPLE_RATE);
    gProcessedSamples.store(targetSamples);

    // 디코더 다시 시작
    gDecodeRunning.store(true);
    gDecodeThread = std::thread(decodeThreadFunc);

    // 원래 재생/일시정지 상태 복원
    gPaused.store(wasPaused);
}

// ─────────────────────────────
// FFI Entry Points
// ─────────────────────────────
extern "C"
{

    void st_create()
    {
        if (gEngineCreated.load())
        {
            return;
        }

        logLine("FFI", "st_create called");

        initSoundTouch();

        if (!initAudioDevice())
        {
            logLine("FFI", "audio device init failed");
            return;
        }

        if (ma_device_start(&gDevice) == MA_SUCCESS)
        {
            gDeviceStarted.store(true);
            gRunning.store(true);
            gEngineCreated.store(true);

            gPaused.store(true);

            logLine("FFI", "playback device started");
        }
        else
        {
            logLine("FFI", "device start failed");
        }
    }

    void st_dispose()
    {
        if (!gEngineCreated.load())
        {
            return;
        }

        logLine("FFI", "st_dispose called");

        closeFileInternal();

        if (gDeviceStarted.load())
        {
            ma_device_uninit(&gDevice);
            gDeviceStarted.store(false);
        }

        {
            std::lock_guard<std::mutex> lock(gMutex);
            gST.clear();
            gST.flush();
            std::fill(gLastBuffer.begin(), gLastBuffer.end(), 0.0f);
        }

        gStable.clear();
        gProcessedSamples.store(0);

        gRunning.store(false);
        gEngineCreated.store(false);
        gPaused.store(true);

        logLine("FFI", "disposed");
    }

    bool st_openFile(const char *path)
    {
        if (!gEngineCreated.load())
        {
            st_create();
        }

        logLine("FFI", "st_openFile called");
        if (!path)
        {
            logLine("FFI", "st_openFile: null path");
            return false;
        }

        if (!openFileInternal(path))
        {
            logLine("FFI", "st_openFile: open failed");
            return false;
        }

        // 파일 열어도 기본은 정지 상태
        gPaused.store(true);

        // 디코더 쓰레드 시작
        gDecodeRunning.store(true);
        gDecodeThread = std::thread(decodeThreadFunc);

        return true;
    }

    void st_close()
    {
        logLine("FFI", "st_close called");
        closeFileInternal();
    }

    void st_set_tempo(float t)
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.setTempo(t);
        applySoundTouchParams_unsafe();
        std::printf("[ST] tempo=%.3f\n", t);
    }

    void st_set_pitch_semitones(float semi)
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.setPitchSemiTones(semi);
        applySoundTouchParams_unsafe();
        std::printf("[ST] pitch=%.3f\n", semi);
    }

    void st_set_volume(float v)
    {
        gVolume.store(v);
        std::printf("[ST] volume=%.3f\n", v);
    }

    double st_get_playback_time()
    {
        double sec = static_cast<double>(gProcessedSamples.load()) / static_cast<double>(SAMPLE_RATE);
        return sec;
    }

    double st_getDurationMs()
    {
        return gDurationMs;
    }

    double st_getPositionMs()
    {
        double sec = static_cast<double>(gProcessedSamples.load()) / static_cast<double>(SAMPLE_RATE);
        return sec * 1000.0;
    }

    void st_seekToMs(double ms)
    {
        seekInternal(ms);
    }

    void st_copyLastBuffer(float *dst, int maxFrames)
    {
        if (!dst || maxFrames <= 0)
            return;
        int frames = std::min<int>(maxFrames, BUF_FRAMES);

        std::memcpy(
            dst,
            gLastBuffer.data(),
            frames * CHANNELS * sizeof(float));
    }

    double st_getRmsLevel()
    {
        double sum = 0.0;
        int N = BUF_FRAMES * CHANNELS;

        for (int i = 0; i < N; ++i)
        {
            float v = gLastBuffer[i];
            sum += static_cast<double>(v) * static_cast<double>(v);
        }
        return std::sqrt(sum / static_cast<double>(N));
    }

    void st_feed_pcm(float * /*data*/, int /*frames*/)
    {
        // legacy no-op
    }

    void st_play()
    {
        if (!gEngineCreated.load())
        {
            return;
        }
        logLine("FFI", "st_play called");
        gPaused.store(false);
    }

    void st_pause()
    {
        if (!gEngineCreated.load())
        {
            return;
        }
        logLine("FFI", "st_pause called");
        gPaused.store(true);
    }

} // extern "C"
