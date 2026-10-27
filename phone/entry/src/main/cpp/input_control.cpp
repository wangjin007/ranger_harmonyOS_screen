#include "input_control.h"

#include <chrono>

#include <hilog/log.h>
#include <multimodalinput/oh_input_manager.h>
#include <window_manager/oh_display_manager.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "OHScreen"

namespace {

uint16_t Be16(const uint8_t *p)
{
    return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | p[1]);
}

int64_t NowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

void OnInjectionAuthorized(Input_InjectionStatus status)
{
    OH_LOG_INFO(LOG_APP, "input injection status %{public}d", static_cast<int>(status));
}

void InjectTouch(int action, int normX, int normY)
{
    int32_t dw = 0;
    int32_t dh = 0;
    if (OH_NativeDisplayManager_GetDefaultDisplayWidth(&dw) != DISPLAY_MANAGER_OK ||
        OH_NativeDisplayManager_GetDefaultDisplayHeight(&dh) != DISPLAY_MANAGER_OK || dw <= 1 || dh <= 1) {
        return;
    }
    const int px = normX * (dw - 1) / 65535;
    const int py = normY * (dh - 1) / 65535;
    Input_TouchEvent *ev = OH_Input_CreateTouchEvent();
    if (ev == nullptr) {
        return;
    }
    int act = TOUCH_ACTION_MOVE;
    if (action == 1) {
        act = TOUCH_ACTION_DOWN;
    } else if (action == 3) {
        act = TOUCH_ACTION_UP;
    } else if (action == 0) {
        act = TOUCH_ACTION_CANCEL;
    }
    OH_Input_SetTouchEventAction(ev, act);
    OH_Input_SetTouchEventFingerId(ev, 0);
    OH_Input_SetTouchEventDisplayX(ev, px);
    OH_Input_SetTouchEventDisplayY(ev, py);
    OH_Input_SetTouchEventGlobalX(ev, px);
    OH_Input_SetTouchEventGlobalY(ev, py);
    uint64_t displayId = 0;
    if (OH_NativeDisplayManager_GetDefaultDisplayId(&displayId) == DISPLAY_MANAGER_OK) {
        OH_Input_SetTouchEventDisplayId(ev, static_cast<int32_t>(displayId));
    }
    OH_Input_SetTouchEventActionTime(ev, NowMs());
    int32_t rc = OH_Input_InjectTouchEventGlobal(ev);
    if (rc != INPUT_SUCCESS) {
        rc = OH_Input_InjectTouchEvent(ev);
    }
    if (rc != INPUT_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "inject touch %{public}d", rc);
    }
    OH_Input_DestroyTouchEvent(&ev);
}

void InjectKey(int action, int keyCode)
{
    Input_KeyEvent *ev = OH_Input_CreateKeyEvent();
    if (ev == nullptr) {
        return;
    }
    OH_Input_SetKeyEventAction(ev, action == 1 ? KEY_ACTION_DOWN : KEY_ACTION_UP);
    OH_Input_SetKeyEventKeyCode(ev, keyCode);
    OH_Input_SetKeyEventActionTime(ev, NowMs());
    const int32_t rc = OH_Input_InjectKeyEvent(ev);
    if (rc != INPUT_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "inject key %{public}d code %{public}d", rc, keyCode);
    }
    OH_Input_DestroyKeyEvent(&ev);
}

} // namespace

void RequestInputInjection()
{
    Input_InjectionStatus status = UNAUTHORIZED;
    if (OH_Input_QueryAuthorizedStatus(&status) == INPUT_SUCCESS && status == AUTHORIZED) {
        return;
    }
    const Input_Result rc = OH_Input_RequestInjection(OnInjectionAuthorized);
    OH_LOG_INFO(LOG_APP, "request input injection %{public}d", static_cast<int>(rc));
}

void ApplyRemoteInput(const uint8_t packet[12])
{
    const int type = packet[4];
    const int action = packet[5];
    const int a = Be16(packet + 6);
    const int b = Be16(packet + 8);
    if (type == 2) {
        InjectTouch(action, a, b);
    } else if (type == 3) {
        InjectKey(action, a);
    }
}
