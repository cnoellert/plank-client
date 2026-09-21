#include "PlankTransportBridge.h"

#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#if PLANK_NATIVE_TRANSPORT
#include <plank_transport.h>
#include <plank_transport_control.h>
#include <plank_transport_setup.h>
#endif

struct PlankVisionTransport {
#if PLANK_NATIVE_TRANSPORT
    PlankTransportNativeEndpoint *endpoint;
#else
    void *endpoint;
#endif
};

static void set_error(char *error, size_t capacity, const char *message) {
    if (error == NULL || capacity == 0) return;
    snprintf(error, capacity, "%s", message == NULL ? "Unknown transport error" : message);
}

#if PLANK_NATIVE_TRANSPORT
static int approve_expected_peer_certificate(
    PlankTransportNativeEndpoint *endpoint,
    const char *expected_sha256,
    char *error,
    size_t error_capacity) {
    size_t certificate_size = 0;
    int32_t result = plank_transport_native_endpoint_peer_certificate(
        endpoint, NULL, 0, &certificate_size);
    if (result != PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL ||
            certificate_size == 0 || certificate_size > 1024 * 1024) {
        set_error(error, error_capacity,
                  "The Host did not provide a valid transport certificate");
        return -1;
    }

    uint8_t *certificate = malloc(certificate_size);
    if (certificate == NULL) {
        set_error(error, error_capacity,
                  "Unable to inspect the Host transport certificate");
        return -1;
    }
    result = plank_transport_native_endpoint_peer_certificate(
        endpoint, certificate, certificate_size, &certificate_size);
    if (result != PLANK_TRANSPORT_OK) {
        free(certificate);
        set_error(error, error_capacity,
                  "Unable to read the Host transport certificate");
        return -1;
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(certificate, (CC_LONG)certificate_size, digest);
    free(certificate);

    char actual_sha256[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
        snprintf(actual_sha256 + index * 2, 3, "%02x", digest[index]);
    }
    actual_sha256[sizeof(actual_sha256) - 1] = '\0';
    if (expected_sha256 == NULL || strcasecmp(actual_sha256, expected_sha256) != 0) {
        set_error(error, error_capacity,
                  "The Host transport certificate changed after sign-in");
        return -1;
    }
    if (plank_transport_native_endpoint_approve_peer_certificate(endpoint) !=
            PLANK_TRANSPORT_OK) {
        set_error(error, error_capacity,
                  "Unable to approve the Host transport certificate");
        return -1;
    }
    return 0;
}
#endif

PlankVisionTransport *plank_vision_transport_connect(
    const char *remote_host,
    uint16_t remote_port,
    const char *certificate_sha256,
    const char *session_token,
    uint32_t maximum_udp_payload,
    char *error,
    size_t error_capacity) {
#if !PLANK_NATIVE_TRANSPORT
    (void)remote_host; (void)remote_port; (void)certificate_sha256;
    (void)session_token; (void)maximum_udp_payload;
    set_error(error, error_capacity, "Native PLANK transport is not linked");
    return NULL;
#else
    if (remote_host == NULL || remote_host[0] == '\0' || remote_port == 0 ||
            certificate_sha256 == NULL || session_token == NULL) {
        set_error(error, error_capacity, "Invalid native transport configuration");
        return NULL;
    }

    char remote_address[512];
    const char *format = strchr(remote_host, ':') == NULL ? "%s:%u" : "[%s]:%u";
    if (snprintf(remote_address, sizeof(remote_address), format,
                 remote_host, (unsigned)remote_port) >= (int)sizeof(remote_address)) {
        set_error(error, error_capacity, "Native transport address is too long");
        return NULL;
    }

    PlankVisionTransport *transport = calloc(1, sizeof(*transport));
    if (transport == NULL) {
        set_error(error, error_capacity, "Unable to allocate native transport");
        return NULL;
    }

    PlankTransportConfig config = {0};
    config.struct_size = sizeof(config);
    config.abi_version = PLANK_TRANSPORT_ABI_VERSION;
    config.mode = PLANK_TRANSPORT_MODE_CLIENT;
    config.handshake_timeout_ms = 10000;
    config.idle_timeout_ms = 30000;
    config.keep_alive_interval_ms = 5000;
    config.session_mode = PLANK_TRANSPORT_SESSION_ACTIVE;
    config.max_udp_payload_size = maximum_udp_payload;
    config.remote_address = remote_address;
    config.server_name = "plank";
    config.certificate_sha256 = certificate_sha256;
    config.session_token = session_token;

    int32_t result = plank_transport_native_endpoint_create(
        &config, &transport->endpoint);
    if (result == PLANK_TRANSPORT_OK) {
        result = plank_transport_native_endpoint_start(transport->endpoint);
    }
    if (result == PLANK_TRANSPORT_OK) {
        const unsigned int attempts = 1200;
        unsigned int attempt = 0;
        int peer_certificate_approved = 0;
        for (; attempt < attempts; ++attempt) {
            const uint32_t state = plank_transport_native_endpoint_state(
                transport->endpoint);
            if (state == PLANK_TRANSPORT_STATE_PEER_VALIDATION &&
                    !peer_certificate_approved) {
                if (approve_expected_peer_certificate(
                        transport->endpoint, certificate_sha256,
                        error, error_capacity) != 0) {
                    result = PLANK_TRANSPORT_ERROR_RUNTIME;
                    break;
                }
                peer_certificate_approved = 1;
            }
            if (state == PLANK_TRANSPORT_STATE_READY) break;
            if (state == PLANK_TRANSPORT_STATE_FAILED ||
                    state == PLANK_TRANSPORT_STATE_STOPPED) {
                result = PLANK_TRANSPORT_ERROR_RUNTIME;
                break;
            }
            usleep(10000);
        }
        if (attempt == attempts) result = PLANK_TRANSPORT_TIMEOUT;
    }
    if (result != PLANK_TRANSPORT_OK) {
        if (transport->endpoint != NULL) {
            if (error == NULL || error_capacity == 0 || error[0] == '\0') {
                plank_transport_native_endpoint_last_error(
                    transport->endpoint, error, error_capacity);
            }
            if (error != NULL && error[0] == '\0') {
                set_error(error, error_capacity,
                          "The secure transport setup did not become ready");
            }
            plank_transport_native_endpoint_stop(transport->endpoint);
            plank_transport_native_endpoint_destroy(transport->endpoint);
        } else {
            set_error(error, error_capacity, "Unable to create native transport");
        }
        free(transport);
        return NULL;
    }
    return transport;
#endif
}

int32_t plank_vision_transport_negotiate(
    PlankVisionTransport *transport,
    const uint8_t *request_json,
    size_t request_size,
    uint8_t *response_json,
    size_t response_capacity,
    size_t *response_size,
    char *error,
    size_t error_capacity) {
#if !PLANK_NATIVE_TRANSPORT
    (void)transport; (void)request_json; (void)request_size;
    (void)response_json; (void)response_capacity; (void)response_size;
    set_error(error, error_capacity, "Native PLANK transport is not linked");
    return PLANK_VISION_TRANSPORT_UNAVAILABLE;
#else
    if (transport == NULL || transport->endpoint == NULL || request_json == NULL ||
            request_size == 0 || response_json == NULL || response_size == NULL) {
        set_error(error, error_capacity, "Invalid session negotiation state");
        return PLANK_VISION_TRANSPORT_ERROR;
    }

    uint8_t packet[PLANK_TRANSPORT_SETUP_MAX_PACKET_SIZE];
    size_t packet_size = 0;
    if (plank_transport_setup_encode(
            PLANK_TRANSPORT_SETUP_LAUNCH_REQUEST, 0,
            PLANK_TRANSPORT_SETUP_STATUS_OK, 1,
            request_json, request_size,
            packet, sizeof(packet), &packet_size) != 0 ||
        plank_transport_native_data_send(
            transport->endpoint, packet, packet_size) != PLANK_TRANSPORT_OK) {
        set_error(error, error_capacity, "Unable to send native session request");
        return PLANK_VISION_TRANSPORT_ERROR;
    }

    packet_size = 0;
    if (plank_transport_native_data_receive(
            transport->endpoint, packet, sizeof(packet), &packet_size, 12000) !=
            PLANK_TRANSPORT_OK) {
        set_error(error, error_capacity, "The Host did not complete session negotiation");
        return PLANK_VISION_TRANSPORT_ERROR;
    }

    PlankTransportSetupPacket response = {0};
    if (plank_transport_setup_decode(packet, packet_size, &response) != 0 ||
            response.request_id != 1 ||
            (response.flags & PLANK_TRANSPORT_SETUP_FLAG_RESPONSE) == 0 ||
            (response.type != PLANK_TRANSPORT_SETUP_LAUNCH_RESPONSE &&
             response.type != PLANK_TRANSPORT_SETUP_ERROR)) {
        set_error(error, error_capacity, "The Host returned an invalid session response");
        return PLANK_VISION_TRANSPORT_ERROR;
    }
    if (response.payload_size > response_capacity) {
        *response_size = response.payload_size;
        set_error(error, error_capacity, "Session response buffer is too small");
        return PLANK_VISION_TRANSPORT_BUFFER_TOO_SMALL;
    }
    memcpy(response_json, response.payload, response.payload_size);
    *response_size = response.payload_size;
    if (response.status != PLANK_TRANSPORT_SETUP_STATUS_OK ||
            response.type == PLANK_TRANSPORT_SETUP_ERROR) {
        set_error(error, error_capacity, "The Host rejected native session negotiation");
        return PLANK_VISION_TRANSPORT_ERROR;
    }
    return PLANK_VISION_TRANSPORT_OK;
#endif
}

int32_t plank_vision_transport_receive_video(
    PlankVisionTransport *transport,
    PlankVisionVideoFrame *frame,
    uint8_t *payload,
    size_t payload_capacity,
    size_t *payload_size,
    uint32_t timeout_ms) {
#if !PLANK_NATIVE_TRANSPORT
    (void)transport; (void)frame; (void)payload; (void)payload_capacity;
    (void)payload_size; (void)timeout_ms;
    return PLANK_VISION_TRANSPORT_UNAVAILABLE;
#else
    if (transport == NULL || transport->endpoint == NULL || frame == NULL) {
        return PLANK_VISION_TRANSPORT_ERROR;
    }
    PlankTransportNativeVideoFrameInfo info = {0};
    info.struct_size = sizeof(info);
    const int32_t result = plank_transport_native_video_receive(
        transport->endpoint, &info, payload, payload_capacity,
        payload_size, timeout_ms);
    if (result == PLANK_TRANSPORT_TIMEOUT) return PLANK_VISION_TRANSPORT_TIMEOUT;
    if (result == PLANK_TRANSPORT_ERROR_BUFFER_TOO_SMALL) {
        return PLANK_VISION_TRANSPORT_BUFFER_TOO_SMALL;
    }
    if (result != PLANK_TRANSPORT_OK) return PLANK_VISION_TRANSPORT_ERROR;

    frame->codec = info.codec;
    frame->flags = info.flags;
    frame->frame_number = info.frame_number;
    frame->pts_90khz = info.pts;
    frame->host_processing_latency = info.host_processing_latency;
    return PLANK_VISION_TRANSPORT_OK;
#endif
}

void plank_vision_transport_disconnect(PlankVisionTransport *transport) {
    if (transport == NULL) return;
#if PLANK_NATIVE_TRANSPORT
    if (transport->endpoint != NULL) {
        uint8_t packet[PLANK_TRANSPORT_CONTROL_MAX_PACKET_SIZE];
        size_t packet_size = 0;
        if (plank_transport_control_encode(
                PLANK_TRANSPORT_CONTROL_CLIENT_DISCONNECT, NULL, 0,
                packet, sizeof(packet), &packet_size) == 0) {
            (void)plank_transport_native_data_send(
                transport->endpoint, packet, packet_size);
        }
        plank_transport_native_endpoint_stop(transport->endpoint);
        plank_transport_native_endpoint_destroy(transport->endpoint);
    }
#endif
    free(transport);
}
