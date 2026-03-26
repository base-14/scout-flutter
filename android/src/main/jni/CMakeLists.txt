cmake_minimum_required(VERSION 3.10)
project(scout_crash_handler)

add_library(scout_crash_handler SHARED scout_crash_handler.c)
target_link_libraries(scout_crash_handler log)
