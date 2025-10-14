// native/soundtouch_ffi.cpp
// v1.90.3 | SoundTouch wrapper for Dart FFI (return type fix for putSamples)

#include "soundtouch_ffi.h"
// Homebrew installs headers under soundtouch/
#include <soundtouch/SoundTouch.h>
#include <memory>
#include <vector>
#include <mutex>

using namespace soundtouch;

struct STContext
{
    std::mutex mtx;
    std::unique_ptr<SoundTouch> st;
    int sr = 44100;
    int ch = 2;

    STContext()
    {
        st = std::make_unique<SoundTouch>();
        // defaults
        st->setSampleRate(sr);
        st->setChannels(ch);
        st->setTempo(1.0f);
        st->setPitchSemiTones(0.0f);
        st->setRate(1.0f);

        // 레슨용 추천 설정(부드러움 우선)
        st->setSetting(SETTING_SEQUENCE_MS, 82);
        st->setSetting(SETTING_SEEKWINDOW_MS, 28);
        st->setSetting(SETTING_OVERLAP_MS, 12);
    }
};

static STContext *cast(st_handle h) { return reinterpret_cast<STContext *>(h); }

extern "C"
{

    ST_API st_handle st_create()
    {
        try
        {
            return reinterpret_cast<st_handle>(new STContext());
        }
        catch (...)
        {
            return nullptr;
        }
    }

    ST_API void st_dispose(st_handle h)
    {
        if (!h)
            return;
        auto ctx = cast(h);
        delete ctx;
    }

    ST_API void st_set_samplerate(st_handle h, int sample_rate)
    {
        if (!h)
            return;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        ctx->sr = sample_rate;
        ctx->st->setSampleRate(sample_rate);
    }

    ST_API void st_set_channels(st_handle h, int channels)
    {
        if (!h)
            return;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        ctx->ch = channels;
        ctx->st->setChannels(channels);
    }

    ST_API void st_set_tempo(st_handle h, double tempo)
    {
        if (!h)
            return;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        ctx->st->setTempo(static_cast<float>(tempo));
    }

    ST_API void st_set_pitch_semitones(st_handle h, double semi)
    {
        if (!h)
            return;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        ctx->st->setPitchSemiTones(static_cast<float>(semi));
    }

    ST_API void st_set_rate(st_handle h, double rate)
    {
        if (!h)
            return;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        ctx->st->setRate(static_cast<float>(rate));
    }

    ST_API int st_put_samples(st_handle h, const float *samples, int frames)
    {
        if (!h || !samples || frames <= 0)
            return 0;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        // SoundTouch::putSamples returns void → 호출 후 입력 프레임 수를 그대로 반환
        ctx->st->putSamples(const_cast<float *>(samples), static_cast<uint>(frames));
        return frames;
    }

    ST_API int st_receive_samples(st_handle h, float *out_samples, int max_frames)
    {
        if (!h || !out_samples || max_frames <= 0)
            return 0;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        // returns number of received samples (frames)
        return static_cast<int>(ctx->st->receiveSamples(out_samples, static_cast<uint>(max_frames)));
    }

    ST_API int st_flush(st_handle h)
    {
        if (!h)
            return 0;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        ctx->st->flush(); // void
        return 1;         // 성공 신호용
    }

    ST_API void st_clear(st_handle h)
    {
        if (!h)
            return;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        ctx->st->clear();
    }

    ST_API int st_get_latency(st_handle h)
    {
        if (!h)
            return 0;
        auto ctx = cast(h);
        std::lock_guard<std::mutex> lock(ctx->mtx);
        // number of samples still inside SoundTouch pipeline
        return static_cast<int>(ctx->st->numUnprocessedSamples());
    }

} // extern "C"
