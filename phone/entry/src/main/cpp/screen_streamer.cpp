#include "screen_streamer.h"

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avscreen_capture_errors.h>
#include <native_window/external_window.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "OHScreen"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

namespace {
constexpr int kStateIdle = 0;
constexpr int kStateListening = 1;
constexpr int kStateStreaming = 2;
constexpr int kStateError = 3;
constexpr int kBacklog = 1;
constexpr int kPollMs = 200;
constexpr char kMagic[4] = {'O', 'H', 'S', 'C'};

void PutBe16(uint8_t *p, uint16_t v)
{
    p[0] = static_cast<uint8_t>((v >> 8) & 0xff);
    p[1] = static_cast<uint8_t>(v & 0xff);
}

void PutBe32(uint8_t *p, uint32_t v)
{
    p[0] = static_cast<uint8_t>((v >> 24) & 0xff);
    p[1] = static_cast<uint8_t>((v >> 16) & 0xff);
    p[2] = static_cast<uint8_t>((v >> 8) & 0xff);
    p[3] = static_cast<uint8_t>(v & 0xff);
}

void PutBe64(uint8_t *p, uint64_t v)
{
    PutBe32(p, static_cast<uint32_t>(v >> 32));
    PutBe32(p + 4, static_cast<uint32_t>(v & 0xffffffffu));
}

void OnEncError(OH_AVCodec *codec, int32_t errorCode, void *userData)
{
    (void)codec;
    (void)userData;
    OH_LOG_ERROR(LOG_APP, "encoder error %{public}d", errorCode);
}

void OnEncStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData)
{
    auto *self = static_cast<ScreenStreamer *>(userData);
    if (self == nullptr) {
        return;
    }
    OH_AVFormat *fmt = format;
    OH_AVFormat *owned = nullptr;
    if (fmt == nullptr && codec != nullptr) {
        owned = OH_VideoEncoder_GetOutputDescription(codec);
        fmt = owned;
    }
    if (fmt == nullptr) {
        return;
    }
    uint8_t *cfg = nullptr;
    size_t cfgSize = 0;
    if (OH_AVFormat_GetBuffer(fmt, OH_MD_KEY_CODEC_CONFIG, &cfg, &cfgSize) && cfg != nullptr && cfgSize > 0) {
        OH_LOG_INFO(LOG_APP, "encoder codec config %{public}zu bytes", cfgSize);
        self->SendCodecConfig(cfg, static_cast<int32_t>(cfgSize));
    }
    if (owned != nullptr) {
        OH_AVFormat_Destroy(owned);
    }
}

void OnEncNeedInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    (void)codec;
    (void)index;
    (void)buffer;
    (void)userData;
}

void OnEncOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    auto *self = static_cast<ScreenStreamer *>(userData);
    if (self == nullptr || codec == nullptr || buffer == nullptr) {
        return;
    }
    OH_AVCodecBufferAttr attr;
    memset(&attr, 0, sizeof(attr));
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
        OH_VideoEncoder_FreeOutputBuffer(codec, index);
        return;
    }
    if (attr.size > 0) {
        uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
        if (addr != nullptr) {
            const uint8_t *data = addr + attr.offset;
            if ((attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0) {
                self->SendCodecConfig(data, attr.size);
            } else {
                self->HandleEncoderOutput(attr.pts, data, attr.size, attr.flags);
            }
        }
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

void OnCaptureError(struct OH_AVScreenCapture *capture, int32_t errorCode, void *userData)
{
    (void)capture;
    OH_LOG_ERROR(LOG_APP, "capture error %{public}d", errorCode);
    auto *self = static_cast<ScreenStreamer *>(userData);
    if (self != nullptr) {
        self->NotifyCaptureReady(-1);
        self->MarkClientDead();
    }
}

void OnCaptureState(struct OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode stateCode, void *userData)
{
    OH_LOG_INFO(LOG_APP, "capture state %{public}d", static_cast<int>(stateCode));
    auto *self = static_cast<ScreenStreamer *>(userData);
    if (self == nullptr) {
        return;
    }
    switch (stateCode) {
        case OH_SCREEN_CAPTURE_STATE_STARTED:
            OH_AVScreenCapture_SetMaxVideoFrameRate(capture, 30);
            self->NotifyCaptureReady(1);
            break;
        case OH_SCREEN_CAPTURE_STATE_CANCELED:
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
            self->NotifyCaptureReady(-1);
            self->MarkClientDead();
            break;
        default:
            break;
    }
}

void OnDisplaySelected(struct OH_AVScreenCapture *capture, uint64_t displayId, void *userData)
{
    (void)capture;
    (void)userData;
    OH_LOG_INFO(LOG_APP, "display selected %{public}llu", static_cast<unsigned long long>(displayId));
}

} // namespace

ScreenStreamer &ScreenStreamer::Get()
{
    static ScreenStreamer inst;
    return inst;
}

int ScreenStreamer::Start(int port, int width, int height, int fps, int bitrate, uint64_t displayId)
{
    if (running_.load()) {
        return 0;
    }
    port_ = port > 0 ? port : 27183;
    width_ = width > 0 ? (width & ~1) : 720;
    height_ = height > 0 ? (height & ~1) : 1280;
    fps_ = fps > 0 ? fps : 30;
    bitrate_ = bitrate > 0 ? bitrate : 8000000;
    displayId_ = displayId;

    listenFd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd_ < 0) {
        OH_LOG_ERROR(LOG_APP, "socket failed: %{public}d", errno);
        state_.store(kStateError);
        return -1;
    }
    int on = 1;
    setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(static_cast<uint16_t>(port_));
    if (bind(listenFd_, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
        OH_LOG_ERROR(LOG_APP, "bind %{public}d failed: %{public}d", port_, errno);
        close(listenFd_);
        listenFd_ = -1;
        state_.store(kStateError);
        return -1;
    }
    if (listen(listenFd_, kBacklog) < 0) {
        OH_LOG_ERROR(LOG_APP, "listen failed: %{public}d", errno);
        close(listenFd_);
        listenFd_ = -1;
        state_.store(kStateError);
        return -1;
    }

    running_.store(true);
    clientDead_.store(false);
    state_.store(kStateListening);
    acceptThread_ = std::thread([this]() { AcceptLoop(); });
    OH_LOG_INFO(LOG_APP, "listening on %{public}d (%{public}dx%{public}d @%{public}d)", port_, width_, height_, fps_);
    return 0;
}

int ScreenStreamer::Stop()
{
    running_.store(false);
    NotifyCaptureReady(-1);
    MarkClientDead();
    int fd = listenFd_;
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
        listenFd_ = -1;
    }
    if (acceptThread_.joinable()) {
        acceptThread_.join();
    }
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (clientFd_ >= 0) {
            close(clientFd_);
            clientFd_ = -1;
        }
    }
    StopCapture();
    state_.store(kStateIdle);
    return 0;
}

int ScreenStreamer::State() const
{
    return state_.load();
}

void ScreenStreamer::MarkClientDead()
{
    clientDead_.store(true);
    startCv_.notify_all();
    std::lock_guard<std::mutex> lock(mu_);
    if (clientFd_ >= 0) {
        shutdown(clientFd_, SHUT_RDWR);
    }
}

void ScreenStreamer::NotifyCaptureReady(int result)
{
    {
        std::lock_guard<std::mutex> lock(startMu_);
        captureReady_.store(result);
    }
    startCv_.notify_all();
}

bool ScreenStreamer::SendPacket(int64_t ptsUs, const uint8_t *data, int32_t size)
{
    if (data == nullptr || size <= 0) {
        return true;
    }
    if (!headerSent_.load()) {
        return true;
    }
    int fd = -1;
    {
        std::lock_guard<std::mutex> lock(mu_);
        fd = clientFd_;
    }
    if (fd < 0) {
        return false;
    }
    std::lock_guard<std::mutex> sendLock(sendMu_);
    uint8_t hdr[12];
    PutBe32(hdr, static_cast<uint32_t>(size));
    PutBe64(hdr + 4, static_cast<uint64_t>(ptsUs < 0 ? 0 : ptsUs));
    if (!WriteAll(fd, hdr, sizeof(hdr))) {
        return false;
    }
    return WriteAll(fd, data, static_cast<size_t>(size));
}

void ScreenStreamer::HandleEncoderOutput(int64_t ptsUs, const uint8_t *data, int32_t size, uint32_t flags)
{
    if (data == nullptr || size <= 0) {
        return;
    }

    std::vector<uint8_t> frame;
    int64_t framePts = ptsUs;
    {
        std::lock_guard<std::mutex> lock(frameMu_);
        if (pendingFrame_.empty()) {
            pendingFramePts_ = ptsUs;
        }
        pendingFrame_.insert(pendingFrame_.end(), data, data + size);
        if ((flags & AVCODEC_BUFFER_FLAGS_INCOMPLETE_FRAME) != 0) {
            return;
        }
        frame.swap(pendingFrame_);
        framePts = pendingFramePts_;
        pendingFramePts_ = 0;
    }

    if (!SendPacket(framePts, frame.data(), static_cast<int32_t>(frame.size()))) {
        MarkClientDead();
    }
}

void ScreenStreamer::SendCodecConfig(const uint8_t *data, int32_t size)
{
    if (data == nullptr || size <= 0) {
        return;
    }
    const bool annexB = size >= 4 && data[0] == 0 && data[1] == 0 &&
        (data[2] == 1 || (data[2] == 0 && data[3] == 1));
    if (annexB) {
        SendPacket(0, data, size);
        return;
    }
    if (size < 7 || data[0] != 1) {
        SendPacket(0, data, size);
        return;
    }
    std::vector<uint8_t> annex;
    const uint8_t sc[4] = {0, 0, 0, 1};
    int pos = 6;
    const int numSps = data[5] & 0x1f;
    for (int i = 0; i < numSps && pos + 2 <= size; ++i) {
        const int len = (data[pos] << 8) | data[pos + 1];
        pos += 2;
        if (len <= 0 || pos + len > size) {
            return;
        }
        annex.insert(annex.end(), sc, sc + 4);
        annex.insert(annex.end(), data + pos, data + pos + len);
        pos += len;
    }
    if (pos >= size) {
        if (!annex.empty()) {
            SendPacket(0, annex.data(), static_cast<int32_t>(annex.size()));
        }
        return;
    }
    const int numPps = data[pos++];
    for (int i = 0; i < numPps && pos + 2 <= size; ++i) {
        const int len = (data[pos] << 8) | data[pos + 1];
        pos += 2;
        if (len <= 0 || pos + len > size) {
            break;
        }
        annex.insert(annex.end(), sc, sc + 4);
        annex.insert(annex.end(), data + pos, data + pos + len);
        pos += len;
    }
    if (!annex.empty()) {
        SendPacket(0, annex.data(), static_cast<int32_t>(annex.size()));
    }
}

void ScreenStreamer::RequestKeyFrame()
{
    if (encoder_ == nullptr) {
        return;
    }
    OH_AVFormat *format = OH_AVFormat_Create();
    if (format == nullptr) {
        return;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_REQUEST_I_FRAME, 1);
    OH_VideoEncoder_SetParameter(static_cast<OH_AVCodec *>(encoder_), format);
    OH_AVFormat_Destroy(format);
}

bool ScreenStreamer::WriteAll(int fd, const uint8_t *data, size_t len)
{
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, data + sent, len - sent, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (n == 0) {
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool ScreenStreamer::SendHeader(int fd)
{
    uint8_t hdr[12];
    memcpy(hdr, kMagic, 4);
    hdr[4] = 1;
    hdr[5] = 0;
    PutBe16(hdr + 6, static_cast<uint16_t>(width_));
    PutBe16(hdr + 8, static_cast<uint16_t>(height_));
    hdr[10] = static_cast<uint8_t>(fps_ > 255 ? 255 : fps_);
    hdr[11] = 0;
    return WriteAll(fd, hdr, sizeof(hdr));
}

void ScreenStreamer::AcceptLoop()
{
    while (running_.load()) {
        pollfd pfd;
        pfd.fd = listenFd_;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, kPollMs);
        if (pr <= 0) {
            continue;
        }
        if (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)) {
            break;
        }
        sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        int fd = accept(listenFd_, reinterpret_cast<sockaddr *>(&peer), &peerLen);
        if (fd < 0) {
            if (!running_.load()) {
                break;
            }
            continue;
        }
        OH_LOG_INFO(LOG_APP, "client connected");
        headerSent_.store(false);
        {
            std::lock_guard<std::mutex> lock(mu_);
            clientFd_ = fd;
        }
        clientDead_.store(false);
        if (!StartCapture()) {
            OH_LOG_ERROR(LOG_APP, "StartCapture failed");
            state_.store(kStateError);
            std::lock_guard<std::mutex> lock(mu_);
            close(clientFd_);
            clientFd_ = -1;
            continue;
        }
        if (!SendHeader(fd)) {
            OH_LOG_ERROR(LOG_APP, "send header failed");
            StopCapture();
            std::lock_guard<std::mutex> lock(mu_);
            close(clientFd_);
            clientFd_ = -1;
            continue;
        }
        headerSent_.store(true);
        state_.store(kStateStreaming);
        RequestKeyFrame();
        if (encoder_ != nullptr) {
            OH_AVFormat *outFmt = OH_VideoEncoder_GetOutputDescription(static_cast<OH_AVCodec *>(encoder_));
            if (outFmt != nullptr) {
                uint8_t *cfg = nullptr;
                size_t cfgSize = 0;
                if (OH_AVFormat_GetBuffer(outFmt, OH_MD_KEY_CODEC_CONFIG, &cfg, &cfgSize) && cfg != nullptr &&
                    cfgSize > 0) {
                    SendCodecConfig(cfg, static_cast<int32_t>(cfgSize));
                }
                OH_AVFormat_Destroy(outFmt);
            }
        }
        while (running_.load() && !clientDead_.load()) {
            pollfd cp;
            cp.fd = fd;
            cp.events = POLLIN | POLLHUP | POLLERR;
            cp.revents = 0;
            int cr = poll(&cp, 1, kPollMs);
            if (cr > 0 && (cp.revents & (POLLHUP | POLLERR | POLLNVAL))) {
                break;
            }
            if (cr > 0 && (cp.revents & POLLIN)) {
                uint8_t junk[8];
                ssize_t n = recv(fd, junk, sizeof(junk), 0);
                if (n <= 0) {
                    break;
                }
            }
        }
        OH_LOG_INFO(LOG_APP, "client gone, stop capture");
        headerSent_.store(false);
        StopCapture();
        {
            std::lock_guard<std::mutex> lock(mu_);
            if (clientFd_ >= 0) {
                close(clientFd_);
                clientFd_ = -1;
            }
        }
        if (running_.load()) {
            state_.store(kStateListening);
        }
    }
}

bool ScreenStreamer::CreateEncoder()
{
    encoder_ = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (encoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "create encoder failed");
        return false;
    }
    auto *enc = static_cast<OH_AVCodec *>(encoder_);
    OH_AVCodecCallback cb;
    memset(&cb, 0, sizeof(cb));
    cb.onError = OnEncError;
    cb.onStreamChanged = OnEncStreamChanged;
    cb.onNeedInputBuffer = OnEncNeedInput;
    cb.onNewOutputBuffer = OnEncOutput;
    if (OH_VideoEncoder_RegisterCallback(enc, cb, this) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "register encoder callback failed");
        return false;
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    if (format == nullptr) {
        return false;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height_);
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, static_cast<double>(fps_));
    OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, static_cast<int64_t>(bitrate_));
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, 1000);
    int32_t cfg = OH_VideoEncoder_Configure(enc, format);
    OH_AVFormat_Destroy(format);
    if (cfg != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "encoder configure failed %{public}d", cfg);
        return false;
    }

    OHNativeWindow *window = nullptr;
    if (OH_VideoEncoder_GetSurface(enc, &window) != AV_ERR_OK || window == nullptr) {
        OH_LOG_ERROR(LOG_APP, "GetSurface failed");
        return false;
    }
    nativeWindow_ = window;

    if (OH_VideoEncoder_Prepare(enc) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "encoder prepare failed");
        return false;
    }
    if (OH_VideoEncoder_Start(enc) != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "encoder start failed");
        return false;
    }
    return true;
}

void ScreenStreamer::DestroyEncoder()
{
    if (encoder_ != nullptr) {
        auto *enc = static_cast<OH_AVCodec *>(encoder_);
        OH_VideoEncoder_Stop(enc);
        OH_VideoEncoder_Destroy(enc);
        encoder_ = nullptr;
    }
    if (nativeWindow_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(static_cast<OHNativeWindow *>(nativeWindow_));
        nativeWindow_ = nullptr;
    }
}

bool ScreenStreamer::StartCapture()
{
    StopCapture();
    if (!CreateEncoder()) {
        DestroyEncoder();
        return false;
    }

    OH_AVScreenCapture *capture = OH_AVScreenCapture_Create();
    if (capture == nullptr) {
        OH_LOG_ERROR(LOG_APP, "create capture failed");
        DestroyEncoder();
        return false;
    }
    capture_ = capture;

    OH_AVScreenCapture_SetErrorCallback(capture, OnCaptureError, this);
    OH_AVScreenCapture_SetStateCallback(capture, OnCaptureState, this);
    OH_AVScreenCapture_SetDisplayCallback(capture, OnDisplaySelected, this);

    OH_AVScreenCaptureConfig config;
    memset(&config, 0, sizeof(config));
    // HOME_SCREEN is the official main-display mode. On PC/2-in-1 it shows
    // a privacy confirmation dialog, not a window picker.
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_ORIGINAL_STREAM;
    config.videoInfo.videoCapInfo.displayId = displayId_;
    config.videoInfo.videoCapInfo.videoFrameWidth = width_;
    config.videoInfo.videoCapInfo.videoFrameHeight = height_;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
    config.videoInfo.videoEncInfo.videoCodec = OH_H264;
    config.videoInfo.videoEncInfo.videoBitrate = bitrate_;
    config.videoInfo.videoEncInfo.videoFrameRate = fps_;

    if (OH_AVScreenCapture_Init(capture, config) != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "capture init failed");
        StopCapture();
        return false;
    }
    OH_AVScreenCapture_SetMicrophoneEnabled(capture, false);
    OH_AVScreenCapture_SetCanvasRotation(capture, true);

    captureReady_.store(0);
    auto *window = static_cast<OHNativeWindow *>(nativeWindow_);
    if (OH_AVScreenCapture_StartScreenCaptureWithSurface(capture, window) != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "StartScreenCaptureWithSurface failed");
        StopCapture();
        return false;
    }

    {
        std::unique_lock<std::mutex> lock(startMu_);
        startCv_.wait_for(lock, std::chrono::seconds(90), [this]() {
            return captureReady_.load() != 0 || !running_.load() || clientDead_.load();
        });
    }
    if (captureReady_.load() != 1) {
        OH_LOG_ERROR(LOG_APP, "capture not started ready=%{public}d", captureReady_.load());
        StopCapture();
        return false;
    }
    OH_LOG_INFO(LOG_APP, "capture started mode=HOME_SCREEN");
    return true;
}

void ScreenStreamer::StopCapture()
{
    if (capture_ != nullptr) {
        auto *capture = static_cast<OH_AVScreenCapture *>(capture_);
        OH_AVScreenCapture_StopScreenCapture(capture);
        OH_AVScreenCapture_Release(capture);
        capture_ = nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(frameMu_);
        pendingFrame_.clear();
        pendingFramePts_ = 0;
    }
    DestroyEncoder();
}
