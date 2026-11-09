# ImageProtocolManager (src/MAVLink) built on its own: Qt Core + Gui only, no application.
cmake_minimum_required(VERSION 3.25)
project(QGCMayhem LANGUAGES C CXX)

option(MAYHEM_FUZZ "Fuzz build: libFuzzer harness under the sanitizers, plus the run-once reproducer" OFF)
set(MAYHEM_STANDALONE_MAIN "" CACHE FILEPATH "LLVM run-once driver (StandaloneFuzzTargetMain.c)")
set(MAYHEM_FUZZ_ENGINE "-fsanitize=fuzzer" CACHE STRING "libFuzzer link flag")
set(MAYHEM_LSAN_OFF "" CACHE FILEPATH "LeakSanitizer-off hook linked into every fuzz binary")
set(MAYHEM_MAVLINK_INCLUDE "" CACHE STRING "Generated MAVLink C headers (;-separated)")

get_filename_component(QGC_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
find_package(Qt6 REQUIRED COMPONENTS Core Gui)
set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 20)

add_library(image_protocol OBJECT
    "${QGC_SOURCE_ROOT}/src/MAVLink/ImageProtocolManager.cc"
    "${QGC_SOURCE_ROOT}/src/MAVLink/ImageProtocolManager.h")
target_include_directories(image_protocol PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/stubs" "${QGC_SOURCE_ROOT}/src/MAVLink" ${MAYHEM_MAVLINK_INCLUDE})
target_link_libraries(image_protocol PUBLIC Qt6::Core Qt6::Gui)

if(MAYHEM_FUZZ)
    add_library(mayhem_standalone_main OBJECT "${MAYHEM_STANDALONE_MAIN}")
    set_source_files_properties("${MAYHEM_STANDALONE_MAIN}" PROPERTIES LANGUAGE C)
    add_executable(image_protocol_fuzzer harness/ImageProtocolFuzzer.cc "${MAYHEM_LSAN_OFF}" $<TARGET_OBJECTS:image_protocol>)
    target_link_libraries(image_protocol_fuzzer PRIVATE image_protocol)
    target_link_options(image_protocol_fuzzer PRIVATE ${MAYHEM_FUZZ_ENGINE})
    add_executable(image_protocol_fuzzer_standalone harness/ImageProtocolFuzzer.cc "${MAYHEM_LSAN_OFF}"
        $<TARGET_OBJECTS:image_protocol> $<TARGET_OBJECTS:mayhem_standalone_main>)
    target_link_libraries(image_protocol_fuzzer_standalone PRIVATE image_protocol)
else()
    add_executable(image_protocol_selftest tests/image_protocol_selftest.cc $<TARGET_OBJECTS:image_protocol>)
    target_link_libraries(image_protocol_selftest PRIVATE image_protocol)
endif()
