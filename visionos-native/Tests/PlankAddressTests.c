#include "PlankAddress.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    char address[128];

    assert(plank_vision_numeric_remote_address(
        "127.0.0.1", 28989, address, sizeof(address)) == 0);
    assert(strcmp(address, "127.0.0.1:28989") == 0);

    assert(plank_vision_numeric_remote_address(
        "localhost", 28989, address, sizeof(address)) == 0);
    assert(strcmp(address, "127.0.0.1:28989") == 0);

    assert(plank_vision_numeric_remote_address(
        "::1", 28989, address, sizeof(address)) == 0);
    assert(strcmp(address, "[::1]:28989") == 0);

    assert(plank_vision_numeric_remote_address(
        "", 28989, address, sizeof(address)) != 0);
    assert(plank_vision_numeric_remote_address(
        "localhost", 28989, address, 8) != 0);
    assert(address[0] == '\0');

    puts("Plank address resolution passed");
    return 0;
}
