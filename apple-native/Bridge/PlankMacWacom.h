#ifndef PLANK_MAC_WACOM_H
#define PLANK_MAC_WACOM_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PlankMacWacom PlankMacWacom;
typedef bool (*PlankMacWacomSend)(void*, const uint8_t*, size_t);
// Create on the UI thread for the normal macOS Input Monitoring prompt.
PlankMacWacom* plank_mac_wacom_create(PlankMacWacomSend send, void* context);
void plank_mac_wacom_active(PlankMacWacom*, bool active);
void plank_mac_wacom_control(PlankMacWacom*, const uint8_t*, size_t);
// Bounded driver teardown. Returning also guarantees no more context callbacks.
void plank_mac_wacom_destroy(PlankMacWacom*);
#ifdef __cplusplus
}
#endif
#endif
