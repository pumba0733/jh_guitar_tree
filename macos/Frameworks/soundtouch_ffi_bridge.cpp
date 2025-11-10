#include <cstdio>
#include <cstdint>

// 내부 오디오 체인 함수 선언 (feedSamples 제거됨)
void startPlayback(const char *path);
void stopPlayback();
void setTempo(double value);
void setPitch(double semi);
void setVolume(float v);

extern "C"
{
    // ===== FFI Entry Points =====
    void st_create()
    {
        printf("[FFI] st_create()\n");
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
