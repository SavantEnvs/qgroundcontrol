// Known-answer check of ImageProtocolManager: a complete RAW8U image transfer must emit the exact image.
#include "ImageProtocolManager.h"

#include <QtGui/QImage>

#include <cstdio>
#include <cstring>

mavlink_status_t m_mavlink_status[MAVLINK_COMM_NUM_BUFFERS];
mavlink_status_t *mavlink_get_channel_status(uint8_t chan) { return &m_mavlink_status[chan % MAVLINK_COMM_NUM_BUFFERS]; }

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond) do { g_checks++; if (!(cond)) { g_failures++; std::fprintf(stderr, "CHECK failed: %s\n", #cond); } } while (0)

int main()
{
    ImageProtocolManager manager;
    int images = 0;
    QImage received;
    QObject::connect(&manager, &ImageProtocolManager::imageReady, [&](const QImage &image) { images++; received = image; });

    mavlink_message_t message{};
    mavlink_data_transmission_handshake_t handshake{};
    handshake.size = 8;
    handshake.width = 4;
    handshake.height = 2;
    handshake.packets = 2;
    handshake.type = MAVLINK_DATA_STREAM_IMG_RAW8U;
    handshake.payload = 4;
    handshake.jpg_quality = 50;
    mavlink_msg_data_transmission_handshake_encode_chan(1, 1, MAVLINK_COMM_0, &message, &handshake);
    manager.mavlinkMessageReceived(message);

    for (uint16_t seq = 0; seq < 2; seq++) {
        mavlink_encapsulated_data_t chunk{};
        chunk.seqnr = seq;
        for (int i = 0; i < 4; i++) {
            chunk.data[i] = static_cast<uint8_t>(seq * 4 + i + 1);
        }
        mavlink_msg_encapsulated_data_encode_chan(1, 1, MAVLINK_COMM_0, &message, &chunk);
        manager.mavlinkMessageReceived(message);
        CHECK(images == (seq == 1 ? 1 : 0));
    }

    CHECK(manager.flowImageIndex() == 1);
    CHECK(received.width() == 4);
    CHECK(received.height() == 2);
    CHECK(qGray(received.pixel(0, 0)) == 1);
    CHECK(qGray(received.pixel(3, 0)) == 4);
    CHECK(qGray(received.pixel(2, 1)) == 7);

    // A second image must not be started until the first is done: an unannounced chunk is ignored.
    mavlink_encapsulated_data_t stray{};
    mavlink_msg_encapsulated_data_encode_chan(1, 1, MAVLINK_COMM_0, &message, &stray);
    manager.mavlinkMessageReceived(message);
    CHECK(images == 1);

    if (g_failures == 0) {
        std::printf("ImageProtocolManager selftest: %d checks passed\n", g_checks);
    }
    return g_failures == 0 ? 0 : 1;
}
