#include "PlankMacWacom.h"
// Invokes the production Swift sender through the production C wrapper from
// a foreign thread. Retains the fake driver's sender after wrapper teardown.
#ifdef __cplusplus
extern "C" {
#endif
bool plank_mac_test_worker_send(const uint8_t* bytes, size_t length);
#ifdef __cplusplus
}
#endif
