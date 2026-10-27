#ifndef OHSCREEN_INPUT_CONTROL_H
#define OHSCREEN_INPUT_CONTROL_H

#include <cstdint>

void RequestInputInjection();
void ApplyRemoteInput(const uint8_t packet[12]);

#endif
