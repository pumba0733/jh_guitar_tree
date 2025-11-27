// ─────────────────────────────────────────────────────────────
//  SmartMediaPlayer FFI - FFmpeg + SoundTouch + miniaudio
//  v3.8-FF — STEP 1 / Snapshot FF-1
//
//  구조:
//    FFmpeg 디코더 쓰레드 → SoundTouch.putSamples()
//    miniaudio.data_callback → SoundTouch.receiveSamples()
//    SoT = gProcessedSamples / SAMPLE_RATE
//
//  Dart 쪽:
//    - 현 시점에서는 FFI 시그니처 변경 없음
//    - 기존 심볼(st_create, st_dispose, st_feed_pcm, st_get_playback_time 등)은 유지
//    - 새 심볼(st_openFile, st_close, st_getDurationMs, st_getPositionMs, st_seekToMs) 추가
//    - STEP 2에서 engine_soundtouch_ffi.dart를 이 네이티브 엔진에 맞게 교체 예정
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

// ─────────────────────────────
// 네임스페이스
// ─────────────────────────────
using namespace soundtouch;

// ─────────────────────────────
// 상수
// ─────────────────────────────
static constexpr int SAMPLE_RATE = 44100;
static constexpr int CHANNELS = 2;
static constexpr int BUF_FRAMES = 4096; // RMS / last buffer 용
static constexpr float DEFAULT_TEMPO = 1.0f;
static constexpr float DEFAULT_PITCH = 0.0f; // semitones
static constexpr float DEFAULT_VOL = 1.0f;

// ─────────────────────────────
// 🔧 전역 상태
// ─────────────────────────────

// miniaudio
static ma_device gDevice{};
static std::atomic<bool> gDeviceStarted{false};

// SoundTouch
static SoundTouch gST;
static std::mutex gMutex; // SoundTouch + 공유 버퍼 보호

// 재생 시간 = 실제 출력된 샘플 수 (SoT)
static std::atomic<uint64_t> gProcessedSamples{0};

// 출력 볼륨
static std::atomic<float> gVolume{DEFAULT_VOL};

// 파형·RMS 계산용 마지막 출력 버퍼
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
static std::atomic<bool> gRunning{false}; // "엔진 활성 + 디바이스 동작" 의미
static std::atomic<bool> gPaused{true};   // 🔴 기본은 "정지" 상태

// ─────────────────────────────
// 내부 유틸
// ─────────────────────────────

static inline void logLine(const char *tag, const char *msg)
{
    std::printf("[%s] %s\n", tag, msg);
}

// SoundTouch 파라미터 변경 시 큐 flush
static inline void applySoundTouchParams_unsafe()
{
    // tempo/pitch 변경 후 이전 큐를 비워서
    // 다음 receiveSamples부터 즉시 새 파라미터가 반영되게 한다.
    gST.clear();
    gST.flush();
}

// FFmpeg 초기화 (한 번만)
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

// FFmpeg 파일 닫기 (내부)
static void closeFileInternal()
{
    // 디코드 쓰레드 중지
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
    }

    logLine("FFmpeg", "file closed");
}

// FFmpeg 파일 열기 (내부)
static bool openFileInternal(const char *path)
{
    initFFmpegOnce();
    closeFileInternal(); // 기존 파일 있으면 정리

    // 포맷 열기
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

    // 오디오 스트림 찾기
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

    // 코덱 컨텍스트 생성
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

    // 타임라인 초기화
    gProcessedSamples.store(0);
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gST.clear();
        gST.flush();
    }

    gFileOpened.store(true);

    logLine("FFmpeg", "file opened");
    return true;
}

// 디코더 쓰레드
static void decodeThreadFunc()
{
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();

    const int MAX_DST_SAMPLES = 4096;
    std::vector<float> convBuffer(MAX_DST_SAMPLES * CHANNELS);

    while (gDecodeRunning.load())
    {
        // 🔴 정지 상태면 아무것도 디코드하지 않고 잠깐 쉰다
        if (gPaused.load())
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
            // EOF 등: 잠시 쉰 후 계속 (Loop OFF 상태 가정)
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

            // FFmpeg → float32 stereo interleaved
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
                std::lock_guard<std::mutex> lock(gMutex);
                gST.putSamples(convBuffer.data(), outSamples);
            }
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
}

// miniaudio 콜백
static void data_callback(ma_device * /*pDevice*/, void *pOutput, const void * /*pInput*/, ma_uint32 frameCount)
{
    float *out = static_cast<float *>(pOutput);

    // 🔴 정지 상태 또는 파일 미열림 상태에서는 항상 무음, SoT 증가 없음
    if (gPaused.load() || !gFileOpened.load())
    {
        std::memset(out, 0, frameCount * CHANNELS * sizeof(float));

        {
            std::lock_guard<std::mutex> lock(gMutex);
            int copyFrames = std::min<int>(static_cast<int>(frameCount), BUF_FRAMES);
            std::memset(gLastBuffer.data(), 0, BUF_FRAMES * CHANNELS * sizeof(float));
        }

        // gProcessedSamples 증가시키지 않는다 → SoT 고정
        return;
    }

    int received = 0;
    {
        std::lock_guard<std::mutex> lock(gMutex);

        // SoundTouch에서 변조 샘플 가져오기
        received = gST.receiveSamples(out, static_cast<int>(frameCount));

        // tempo/pitch 변경 직후 buffer 비는 문제 대응
        if (received == 0)
        {
            gST.flush();
            received = gST.receiveSamples(out, static_cast<int>(frameCount));
        }

        // 최근 출력 버퍼 저장
        if (received > 0)
        {
            int copyFrames = std::min<int>(received, BUF_FRAMES);
            std::memcpy(gLastBuffer.data(), out, copyFrames * CHANNELS * sizeof(float));

            if (copyFrames < BUF_FRAMES)
            {
                std::memset(
                    gLastBuffer.data() + copyFrames * CHANNELS,
                    0,
                    (BUF_FRAMES - copyFrames) * CHANNELS * sizeof(float));
            }
        }
        else
        {
            std::memset(gLastBuffer.data(), 0, BUF_FRAMES * CHANNELS * sizeof(float));
        }
    }

    // underflow → 무음 패딩 + 타임라인 증가
    if (received <= 0)
    {
        std::memset(out, 0, frameCount * CHANNELS * sizeof(float));
        gProcessedSamples += frameCount;
        return;
    }

    // 볼륨
    const float vol = gVolume.load();
    int total = received * CHANNELS;
    for (int i = 0; i < total; ++i)
    {
        out[i] *= vol;
    }

    // 부족한 프레임 무음 패딩
    if (received < static_cast<int>(frameCount))
    {
        int padStart = received * CHANNELS;
        int padSamples = static_cast<int>(frameCount) * CHANNELS - padStart;
        std::memset(out + padStart, 0, padSamples * sizeof(float));
    }

    // SoT: 실제 출력된 프레임 수만큼 증가
    gProcessedSamples += received;
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

// ─────────────────────────────
// 🧩 FFI Entry Points
// ─────────────────────────────
extern "C"
{

    // 기본 엔진 생성: FFmpeg/SoundTouch/miniaudio 준비
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

            // 🔴 추가: 엔진 생성 시 기본은 "정지"
            gPaused.store(true);

            logLine("FFI", "playback device started");
        }
        else
        {
            logLine("FFI", "device start failed");
        }
    }

    // 엔진 해제: 파일/디코더/디바이스 모두 정리
    void st_dispose()
    {
        if (!gEngineCreated.load())
        {
            return;
        }

        logLine("FFI", "st_dispose called");

        // 파일/디코더 정리
        closeFileInternal();

        // 오디오 디바이스 종료
        if (gDeviceStarted.load())
        {
            ma_device_uninit(&gDevice);
            gDeviceStarted.store(false);
        }

        {
            std::lock_guard<std::mutex> lock(gMutex);
            gST.clear();
        }

        gRunning.store(false);
        gEngineCreated.store(false);

        logLine("FFI", "disposed");
    }

    // ─────────────────────────
    // FFmpeg 파일 오픈/닫기
    // ─────────────────────────

    // path: UTF-8 C 문자열
    bool st_openFile(const char *path)
    {
        if (!gEngineCreated.load())
        {
            // 안전을 위해 자동 초기화 시도
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

        // 🔴 파일 열어도 여전히 "정지" 상태로 유지
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

    // ─────────────────────────
    // Tempo / Pitch / Volume
    // ─────────────────────────

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

    // ─────────────────────────
    // Position / Duration / Seek
    // ─────────────────────────

    // 재생 시간 (초 단위) — 기존 API 호환용
    double st_get_playback_time()
    {
        double sec = static_cast<double>(gProcessedSamples.load()) / static_cast<double>(SAMPLE_RATE);
        return sec;
    }

    // 총 길이 (ms)
    double st_getDurationMs()
    {
        return gDurationMs;
    }

    // 현재 위치 (ms) — SoT = 출력된 샘플 수 기준
    double st_getPositionMs()
    {
        double sec = static_cast<double>(gProcessedSamples.load()) / static_cast<double>(SAMPLE_RATE);
        return sec * 1000.0;
    }

    // FFmpeg seek (ms 단위)
    void st_seekToMs(double ms)
    {
        if (!gFileOpened.load() || !gFmtCtx || !gCodecCtx || gAudioStreamIndex < 0)
        {
            logLine("FFI", "st_seekToMs: no file");
            return;
        }

        logLine("FFI", "st_seekToMs called");

        // 디코더 쓰레드 잠시 멈추고 join
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
            // FFmpeg 6.x: swr_flush 제거됨 → swr_convert로 내부 버퍼 플러시
            if (gSwr)
            {
                swr_convert(gSwr, nullptr, 0, nullptr, 0);
            }
        }

        {
            std::lock_guard<std::mutex> lock(gMutex);
            gST.clear();
            gST.flush();
        }

        // SoT를 타겟 위치로 재설정
        uint64_t targetSamples = static_cast<uint64_t>((ms / 1000.0) * SAMPLE_RATE);
        gProcessedSamples.store(targetSamples);

        // 디코더 다시 시작
        gDecodeRunning.store(true);
        gDecodeThread = std::thread(decodeThreadFunc);
    }

    // ─────────────────────────
    // Waveform / RMS API
    // ─────────────────────────

    // 최근 출력 버퍼를 복사 (stereo, interleaved)
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

    // RMS 레벨 계산
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

    // ─────────────────────────
    // 레거시 PCM feed API (Step 1에서는 no-op 처리)
    // ─────────────────────────

    void st_feed_pcm(float * /*data*/, int /*frames*/)
    {
        // no-op
    }

    // 🔴 새 재생/일시정지 엔트리 (기존 심볼 유지용)
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
