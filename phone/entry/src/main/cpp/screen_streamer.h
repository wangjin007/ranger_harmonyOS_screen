#ifndef OHSCREEN_SCREEN_STREAMER_H
#define OHSCREEN_SCREEN_STREAMER_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class ScreenStreamer {
public:
    static ScreenStreamer &Get();

    int Start(int port, int width, int height, int fps, int bitrate, uint64_t displayId, int rotationDeg);
    int StartClient(const char *hosts, int port, int width, int height, int fps, int bitrate, uint64_t displayId,
        int rotationDeg, uint32_t pin);
    int UpdateSize(int width, int height, uint64_t displayId, int rotationDeg);
    int Stop();
    int State() const;

    void MarkClientDead();
    void NotifyCaptureReady(int result);
    bool SendPacket(int64_t ptsUs, const uint8_t *data, int32_t size);
    void SendCodecConfig(const uint8_t *data, int32_t size);
    void RequestKeyFrame();
    void HandleEncoderOutput(int64_t ptsUs, const uint8_t *data, int32_t size, uint32_t flags);

private:
    ScreenStreamer() = default;
    ~ScreenStreamer() = default;
    ScreenStreamer(const ScreenStreamer &) = delete;
    ScreenStreamer &operator=(const ScreenStreamer &) = delete;

    void AcceptLoop();
    void ClientLoop();
    void RunSession(int fd);
    int ConnectTcp(const char *host, int port);
    bool SendAuth(int fd);
    bool SendHeader(int fd);
    bool SendOrientationChange(int visW, int visH, int rotationDeg);
    bool SendCurrentCodecConfig();
    bool WriteAll(int fd, const uint8_t *data, size_t len);
    bool StartCapture();
    void StopCapture();
    bool CreateEncoder();
    void DestroyEncoder();

    std::mutex mu_;
    std::mutex sendMu_;
    std::mutex frameMu_;
    std::mutex startMu_;
    std::condition_variable startCv_;
    std::vector<uint8_t> pendingFrame_;
    int64_t pendingFramePts_{0};
    std::atomic<int> captureReady_{0};
    std::atomic<bool> headerSent_{false};
    std::thread acceptThread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> clientDead_{false};
    std::atomic<int> state_{0}; // 0 idle, 1 listening, 2 streaming, 3 error
    int listenFd_{-1};
    int clientFd_{-1};
    int port_{27183};
    int width_{720};
    int height_{1280};
    int fps_{30};
    int bitrate_{8000000};
    int rotationDeg_{0};
    int startRotationDeg_{0};
    uint64_t displayId_{0};
    uint32_t pin_{0};
    std::string hostList_;
    bool clientMode_{false};

    void *capture_{nullptr};
    void *encoder_{nullptr};
    void *nativeWindow_{nullptr};
};

#endif
