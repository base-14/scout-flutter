cmake_minimum_required(VERSION 3.13)
project(scout_crash_handler)

add_library(scout_crash_handler SHARED scout_crash_handler.c)
target_link_libraries(scout_crash_handler log)

# Android 15+ devices can boot with 16 KB memory pages; shared libraries
# whose ELF LOAD segments are aligned to 4 KB fail to load there, and
# Google Play requires 16 KB compliance for apps targeting Android 15+.
# NDK r27+ aligns to 16 KB by default, but this library is compiled by
# each consuming app with whatever NDK that app pins — the flag must be
# explicit to guarantee compliance on older NDKs too.
target_link_options(scout_crash_handler PRIVATE "-Wl,-z,max-page-size=16384")
