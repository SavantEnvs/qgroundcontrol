// Known-answer checks for the MAVLink 2 framing the parser harness drives: pack, parse, compare fields.
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <mavlink.h>

namespace {
int checks = 0;

void expect(bool condition, const char* what)
{
    ++checks;
    if (!condition) {
        std::fprintf(stderr, "FAILED: %s\n", what);
        std::exit(1);
    }
}

uint8_t parseAll(const uint8_t* bytes, uint16_t length, mavlink_message_t* message, mavlink_status_t* status)
{
    uint8_t last = MAVLINK_FRAMING_INCOMPLETE;
    for (uint16_t index = 0; index < length; ++index) {
        last = mavlink_parse_char(MAVLINK_COMM_0, bytes[index], message, status);
    }
    return last;
}
}  // namespace

int main()
{
    mavlink_message_t packed{};
    mavlink_msg_heartbeat_pack(7, 3, &packed, MAV_TYPE_QUADROTOR, MAV_AUTOPILOT_PX4, 81, 12345, MAV_STATE_ACTIVE);
    uint8_t wire[MAVLINK_MAX_PACKET_LEN]{};
    const uint16_t length = mavlink_msg_to_send_buffer(wire, &packed);
    expect(wire[0] == MAVLINK_STX, "frame starts with the MAVLink 2 magic");
    expect(wire[1] == 9, "heartbeat payload is 9 bytes");
    expect(wire[5] == 7 && wire[6] == 3, "system and component ids on the wire");
    expect(length == 12 + 9, "frame length is header + payload + checksum");

    mavlink_reset_channel_status(MAVLINK_COMM_0);
    mavlink_message_t parsed{};
    mavlink_status_t status{};
    expect(parseAll(wire, length, &parsed, &status) == MAVLINK_FRAMING_OK, "intact frame parses");
    expect(parsed.msgid == MAVLINK_MSG_ID_HEARTBEAT, "message id is HEARTBEAT");
    expect(parsed.sysid == 7 && parsed.compid == 3, "ids survive the round trip");
    mavlink_heartbeat_t heartbeat{};
    mavlink_msg_heartbeat_decode(&parsed, &heartbeat);
    expect(heartbeat.type == MAV_TYPE_QUADROTOR, "type decoded");
    expect(heartbeat.autopilot == MAV_AUTOPILOT_PX4, "autopilot decoded");
    expect(heartbeat.base_mode == 81, "base_mode decoded");
    expect(heartbeat.custom_mode == 12345, "custom_mode decoded");
    expect(heartbeat.system_status == MAV_STATE_ACTIVE, "system_status decoded");

    uint8_t corrupted[MAVLINK_MAX_PACKET_LEN]{};
    std::memcpy(corrupted, wire, length);
    corrupted[10] ^= 0xff;
    mavlink_reset_channel_status(MAVLINK_COMM_0);
    int accepted = 0;
    for (uint16_t index = 0; index < length; ++index) {
        if (mavlink_parse_char(MAVLINK_COMM_0, corrupted[index], &parsed, &status) == MAVLINK_FRAMING_OK) {
            ++accepted;
        }
    }
    expect(accepted == 0, "corrupted payload is rejected by the CRC check");
    expect(parseAll(wire, length, &parsed, &status) == MAVLINK_FRAMING_OK, "intact frame after corruption parses");
    expect(parsed.sysid == 7 && parsed.compid == 3, "resynchronised frame carries the original ids");

    std::printf("MAVLink selftest: %d checks passed\n", checks);
    return 0;
}
