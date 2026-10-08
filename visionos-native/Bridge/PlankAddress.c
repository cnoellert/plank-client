#include "PlankAddress.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>

int plank_vision_numeric_remote_address(
    const char *host,
    uint16_t port,
    char *address,
    size_t address_capacity) {
    if (host == NULL || host[0] == '\0' || port == 0 ||
            address == NULL || address_capacity == 0) {
        return -1;
    }
    address[0] = '\0';

    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    struct addrinfo *resolved = NULL;
    if (getaddrinfo(host, NULL, &hints, &resolved) != 0) {
        return -1;
    }

    // The current Linux Host listens on IPv4. Prefer it when both families are
    // present, while retaining numeric IPv6 support for IPv6-only hosts.
    int result = -1;
    for (int family_pass = 0; family_pass < 2 && result != 0; ++family_pass) {
        const int family = family_pass == 0 ? AF_INET : AF_INET6;
        for (const struct addrinfo *entry = resolved; entry != NULL; entry = entry->ai_next) {
            if (entry->ai_family != family) continue;

            char numeric_host[INET6_ADDRSTRLEN];
            if (family == AF_INET) {
                const struct sockaddr_in *socket = (const struct sockaddr_in *)entry->ai_addr;
                if (inet_ntop(AF_INET, &socket->sin_addr,
                              numeric_host, sizeof(numeric_host)) == NULL) {
                    continue;
                }
                const int written = snprintf(address, address_capacity, "%s:%u",
                                             numeric_host, (unsigned)port);
                result = written > 0 && (size_t)written < address_capacity ? 0 : -1;
            } else {
                const struct sockaddr_in6 *socket = (const struct sockaddr_in6 *)entry->ai_addr;
                if (inet_ntop(AF_INET6, &socket->sin6_addr,
                              numeric_host, sizeof(numeric_host)) == NULL) {
                    continue;
                }
                const int written = socket->sin6_scope_id == 0 ?
                    snprintf(address, address_capacity, "[%s]:%u",
                             numeric_host, (unsigned)port) :
                    snprintf(address, address_capacity, "[%s%%%u]:%u",
                             numeric_host, socket->sin6_scope_id, (unsigned)port);
                result = written > 0 && (size_t)written < address_capacity ? 0 : -1;
            }
            if (result == 0) break;
        }
    }
    freeaddrinfo(resolved);
    if (result != 0) address[0] = '\0';
    return result;
}
