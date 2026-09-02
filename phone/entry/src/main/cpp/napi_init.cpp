#include "napi/native_api.h"
#include "screen_streamer.h"

static napi_value StartServer(napi_env env, napi_callback_info info)
{
    size_t argc = 7;
    napi_value args[7] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t port = 27183;
    int32_t width = 720;
    int32_t height = 1280;
    int32_t fps = 30;
    int32_t bitrate = 8000000;
    int64_t displayId = 0;
    int32_t rotationDeg = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &port);
    }
    if (argc > 1) {
        napi_get_value_int32(env, args[1], &width);
    }
    if (argc > 2) {
        napi_get_value_int32(env, args[2], &height);
    }
    if (argc > 3) {
        napi_get_value_int32(env, args[3], &fps);
    }
    if (argc > 4) {
        napi_get_value_int32(env, args[4], &bitrate);
    }
    if (argc > 5) {
        napi_get_value_int64(env, args[5], &displayId);
    }
    if (argc > 6) {
        napi_get_value_int32(env, args[6], &rotationDeg);
    }
    int rc = ScreenStreamer::Get().Start(port, width, height, fps, bitrate,
        displayId < 0 ? 0 : static_cast<uint64_t>(displayId), rotationDeg);
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value UpdateSize(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t width = 0;
    int32_t height = 0;
    int64_t displayId = 0;
    int32_t rotationDeg = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &width);
    }
    if (argc > 1) {
        napi_get_value_int32(env, args[1], &height);
    }
    if (argc > 2) {
        napi_get_value_int64(env, args[2], &displayId);
    }
    if (argc > 3) {
        napi_get_value_int32(env, args[3], &rotationDeg);
    }
    int rc = ScreenStreamer::Get().UpdateSize(width, height,
        displayId < 0 ? 0 : static_cast<uint64_t>(displayId), rotationDeg);
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value StopServer(napi_env env, napi_callback_info info)
{
    (void)info;
    int rc = ScreenStreamer::Get().Stop();
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value GetState(napi_env env, napi_callback_info info)
{
    (void)info;
    int rc = ScreenStreamer::Get().State();
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"startServer", nullptr, StartServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"updateSize", nullptr, UpdateSize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopServer", nullptr, StopServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getState", nullptr, GetState, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module ohscreenModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "ohscreen",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterOHScreenModule(void)
{
    napi_module_register(&ohscreenModule);
}
