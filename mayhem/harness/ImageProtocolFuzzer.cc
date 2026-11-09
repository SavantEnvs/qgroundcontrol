// Feeds MAVLink messages to ImageProtocolManager::mavlinkMessageReceived(), the slot every link delivers
// DATA_TRANSMISSION_HANDSHAKE / ENCAPSULATED_DATA to once the framing layer has parsed and CRC-checked them.
// Input: records of [selector][length][payload...]; selector bit 0 picks the message id, the payload becomes the
// message payload (MAVLink 2 decoders zero-extend a short payload, so any length is a valid message).
#include "ImageProtocolManager.h"

#include <QtCore/QtGlobal>

#include <cstddef>
#include <cstdint>
#include <cstring>

mavlink_status_t m_mavlink_status[MAVLINK_COMM_NUM_BUFFERS];
mavlink_status_t *mavlink_get_channel_status(uint8_t chan) { return &m_mavlink_status[chan % MAVLINK_COMM_NUM_BUFFERS]; }

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    qInstallMessageHandler([](QtMsgType, const QMessageLogContext &, const QString &) {});
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    ImageProtocolManager manager;

    size_t pos = 0;
    while (pos + 2 <= size) {
        const uint8_t selector = data[pos];
        size_t length = data[pos + 1];
        pos += 2;
        if (length > size - pos) {
            length = size - pos;
        }

        mavlink_message_t message{};
        message.msgid = (selector & 1) ? MAVLINK_MSG_ID_ENCAPSULATED_DATA : MAVLINK_MSG_ID_DATA_TRANSMISSION_HANDSHAKE;
        message.len = static_cast<uint8_t>(length);
        std::memcpy(_MAV_PAYLOAD_NON_CONST(&message), data + pos, length);
        pos += length;

        manager.mavlinkMessageReceived(message);
    }
    return 0;
}
