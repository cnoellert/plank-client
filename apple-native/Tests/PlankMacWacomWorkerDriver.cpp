#include "PlankMacWacomWorkerDriver.h"
#include "macrawwacom.h"
#include <thread>

static MacRawWacomInput::SendFrame sender;
class MacRawWacomInput::Impl {};
void MacRawWacomInput::requestPermissionIfNeeded() {}
MacRawWacomInput::MacRawWacomInput(std::function<void()>, SendFrame send) { sender = send; }
MacRawWacomInput::~MacRawWacomInput() = default;
void MacRawWacomInput::setActive(bool) {}
void MacRawWacomInput::handleControl(const unsigned char*, unsigned) {}

extern "C" bool plank_mac_test_worker_send(const uint8_t* bytes, size_t length) {
    bool accepted = false;
    std::thread worker([&] { accepted = sender && sender(bytes, length); });
    worker.join();
    return accepted;
}
