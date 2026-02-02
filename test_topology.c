#include <stdio.h>
#include <stdint.h>
#include "src/clients/c/arch_client.h"

static void on_complete(
    arch_context_t context,
    arch_packet_t* packet,
    uint64_t timestamp,
    const uint8_t* result_ptr,
    uint32_t result_len
) {
    printf("Completion callback: status=%d, result_len=%u\n", packet->status, result_len);
    if (packet->status == ARCH_PACKET_STATUS_OK) {
        printf("SUCCESS! get_topology worked!\n");
        if (result_ptr && result_len > 0) {
            // First 8 bytes should be version (u64)
            uint64_t version = *(uint64_t*)result_ptr;
            printf("Topology version: %lu\n", version);
        }
    } else {
        printf("FAILED with status: %d\n", packet->status);
    }
}

int main() {
    printf("Testing get_topology operation...\n");

    uint128_t cluster_id = 0;
    const char* addresses = "127.0.0.1:3011";

    arch_client_t client;
    int rc = arch_client_init(&client, cluster_id, addresses, on_complete);
    if (rc != 0) {
        printf("Failed to initialize client: %d\n", rc);
        return 1;
    }

    printf("Client initialized\n");

    // Create a TopologyRequest (just 8 bytes of zeros)
    uint64_t request = 0;

    // Create packet
    arch_packet_t packet = {
        .user_data = 0,
        .operation = 157, // get_topology operation code
        .data_size = sizeof(request),
        .data = (uint8_t*)&request,
        .user_tag = 0,
        .status = ARCH_PACKET_STATUS_OK,
    };

    printf("Submitting get_topology request...\n");
    arch_client_submit(&client, &packet);

    // Wait for completion (simple polling)
    for (int i = 0; i < 100; i++) {
        usleep(100000); // 100ms
    }

    arch_client_deinit(&client);
    return 0;
}
