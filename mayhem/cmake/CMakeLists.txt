# Wraps test/GPS/Standalone (QGCGPSCore + QGCNTRIPHttp without the application): adds the run-once reproducers and
# LeakSanitizer hook for the libFuzzer build (MAYHEM_FUZZ=ON), or a known-answer NTRIP decoder check otherwise.
cmake_minimum_required(VERSION 3.25)
project(QGCMayhem LANGUAGES C CXX)
enable_testing()

option(MAYHEM_FUZZ "Fuzz build: libFuzzer harnesses under the sanitizers, plus standalone reproducers" OFF)
set(MAYHEM_STANDALONE_MAIN "" CACHE FILEPATH "LLVM run-once driver (StandaloneFuzzTargetMain.c)")

get_filename_component(QGC_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
file(READ "${QGC_SOURCE_ROOT}/.github/build-config.json" _qgc_build_config)
string(JSON _qgc_qt_minimum_version GET "${_qgc_build_config}" qt minimum_version)
# Resolved here so the imported Qt targets are visible to the Standalone subdirectory and to this one.
find_package(Qt6 ${_qgc_qt_minimum_version} REQUIRED COMPONENTS Core Network SerialPort)

set(QGC_GPS_LIBFUZZER ${MAYHEM_FUZZ} CACHE BOOL "" FORCE)
add_subdirectory("${QGC_SOURCE_ROOT}/test/GPS/Standalone" standalone)

set(_gps_test "${QGC_SOURCE_ROOT}/test/GPS")
if(MAYHEM_FUZZ)
    add_library(mayhem_standalone_main OBJECT "${MAYHEM_STANDALONE_MAIN}")
    set_source_files_properties("${MAYHEM_STANDALONE_MAIN}" PROPERTIES LANGUAGE C)

    foreach(target QGCGPSProtocolFuzz ntrip_http_decoder_fuzzer)
        target_sources(${target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../lsan_off.cc")
    endforeach()

    add_executable(
        gps_protocol_fuzz_standalone
        "${_gps_test}/Core/Protocols/Fuzz/ProtocolFuzz.cc"
        "${CMAKE_CURRENT_SOURCE_DIR}/../lsan_off.cc"
        $<TARGET_OBJECTS:mayhem_standalone_main>
    )
    target_link_libraries(gps_protocol_fuzz_standalone PRIVATE QGCGPSCore QGCGPSProtocolTestSupport)

    add_executable(
        ntrip_http_decoder_fuzzer_standalone
        "${_gps_test}/NTRIP/HTTP/Fuzz/NTRIPHttpDecoderFuzzer.cc"
        "${CMAKE_CURRENT_SOURCE_DIR}/../lsan_off.cc"
        $<TARGET_OBJECTS:mayhem_standalone_main>
    )
    target_link_libraries(ntrip_http_decoder_fuzzer_standalone PRIVATE QGC::NTRIPHttp)
else()
    add_executable(ntrip_decoder_selftest "${CMAKE_CURRENT_SOURCE_DIR}/../tests/ntrip_decoder_selftest.cc")
    target_link_libraries(ntrip_decoder_selftest PRIVATE QGC::NTRIPHttp)
endif()
