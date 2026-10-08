#ifndef PLANK_VISION_ADDRESS_H
#define PLANK_VISION_ADDRESS_H

#include <stddef.h>
#include <stdint.h>

// The native transport ABI requires a numeric SocketAddr, while bookmarks may
// contain DNS names. Resolve before constructing the transport endpoint.
int plank_vision_numeric_remote_address(
    const char *host,
    uint16_t port,
    char *address,
    size_t address_capacity);

#endif
