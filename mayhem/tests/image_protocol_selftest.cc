// Known-answer checks of ImageProtocolManager (src/MAVLink). Default run: the request/cancel messages it builds and
// the handling of a chunk that no handshake announced. `transfer`: a complete RAW8U image transfer must emit the exact image.
#include "ImageProtocolManager.h"

#include <QtGui/QImage>

#include <cstdio>
#include <cstring>

mavlink_status_t m_mavlink_status[MAVLINK_COMM_NUM_BUFFERS];
mavlink_status_t *mavlink_get_channel_status(uint8_t chan) { return &m_mavlink_status[chan % MAVLINK_COMM_NUM_BUFFERS]; }

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond) do { g_checks++; if (!(cond)) { g_failures++; std::fprintf(stderr, "CHECK failed: %s\n", #cond); } } while (0)

static void basic()
{
    ImageProtocolManager manager;
    int images = 0;
    QObject::connect(&manager, &ImageProtocolManager::imageReady, [&](const QImage &) { images++; });

    mavlink_message_t message{};
    mavlink_data_transmission_handshake_t handshake{};
    CHECK(manager.requestImage(7, 9, MAVLINK_COMM_0, message));
    CHECK(message.msgid == MAVLINK_MSG_ID_DATA_TRANSMISSION_HANDSHAKE);
    CHECK(message.sysid == 7);
    CHECK(message.compid == 9);
    mavlink_msg_data_transmission_handshake_decode(&message, &handshake);
    CHECK(handshake.type == MAVLINK_DATA_STREAM_IMG_JPEG);
    CHECK(handshake.jpg_quality == 50);
    CHECK(handshake.size == 0);

    mavlink_message_t cancel{};
    manager.cancelRequest(7, 9, MAVLINK_COMM_0, cancel);
    CHECK(cancel.msgid == MAVLINK_MSG_ID_DATA_TRANSMISSION_HANDSHAKE);
    mavlink_msg_data_transmission_handshake_decode(&cancel, &handshake);
    CHECK(handshake.type == 0);
    CHECK(handshake.jpg_quality == 0);

    // A chunk with no preceding handshake is ignored.
    mavlink_encapsulated_data_t stray{};
    stray.seqnr = 3;
    stray.data[0] = 0x55;
    mavlink_msg_encapsulated_data_encode_chan(1, 1, MAVLINK_COMM_0, &message, &stray);
    manager.mavlinkMessageReceived(message);
    CHECK(images == 0);
    CHECK(manager.flowImageIndex() == 0);
}

static void transfer()
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
}

int main(int argc, char **argv)
{
    const bool full = argc > 1 && std::strcmp(argv[1], "transfer") == 0;
    if (full) {
        transfer();
    } else {
        basic();
    }

    if (g_failures == 0) {
        std::printf("ImageProtocolManager %s selftest: %d checks passed\n", full ? "transfer" : "basic", g_checks);
    }
    return g_failures == 0 ? 0 : 1;
}
