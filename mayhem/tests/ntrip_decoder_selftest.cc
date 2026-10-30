// Known-answer checks for the NTRIP HTTP codec: fixed wire bytes in, asserted decode results out.
#include <cstdio>
#include <cstdlib>

#include <QtCore/QByteArray>
#include <QtCore/QDateTime>

#include "NTRIPHttpCodec.h"

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
}  // namespace

int main()
{
    const auto now = QDateTime::fromString(QStringLiteral("2026-09-18T12:00:00Z"), Qt::ISODate);

    const auto status = NTRIPHttpDecoder::parseStatusLine("HTTP/1.1 404 Not Found");
    expect(status.valid, "status line valid");
    expect(status.code == 404, "status code 404");
    expect(status.reason == QStringLiteral("Not Found"), "status reason");
    expect(!NTRIPHttpDecoder::parseStatusLine("HTTP/1.1 2000 OK").valid, "five-digit code rejected");

    {
        NTRIPHttpDecoder decoder;
        const auto result = decoder.feed("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc", now);
        expect(result.connected, "length: connected");
        expect(result.complete, "length: complete");
        expect(!result.failure, "length: no failure");
        expect(result.body == "abc", "length: body abc");
    }
    {
        NTRIPHttpDecoder decoder;
        const auto result = decoder.feed(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n2\r\nbc\r\n0\r\n\r\n", now);
        expect(result.connected && result.complete && !result.failure, "chunked: connected and complete");
        expect(result.body == "abc", "chunked: body abc");
    }
    {
        NTRIPHttpDecoder decoder;
        const auto result = decoder.feed("ICY 200 OK\r\n\xd3\x10" "RTCM-frame", now);
        expect(result.connected, "icy: connected");
        expect(result.body == QByteArray("\xd3\x10" "RTCM-frame"), "icy: binary stream passed through as the body");
    }
    {
        NTRIPHttpDecoder decoder;
        const auto result = decoder.feed("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n", now);
        expect(result.failure.has_value(), "conflicting framing is a failure");
    }
    std::printf("NTRIP decoder selftest: %d checks passed\n", checks);
    return 0;
}
