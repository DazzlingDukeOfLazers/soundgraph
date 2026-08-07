# SoundGraph generic firmware for ESP32-S3.
#
#   idf.py set-target esp32s3
#   idf.py build flash monitor
#
# Select a board profile with -DSG_BOARD=<id> (a directory under embedded/boards/*/);
# the default is the generic DevKitC + PCM5102 wiring.
cmake_minimum_required(VERSION 3.16)

set(EXTRA_COMPONENT_DIRS ${CMAKE_CURRENT_LIST_DIR}/../components)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(soundgraph-esp32s3)
