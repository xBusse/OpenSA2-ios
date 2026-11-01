# host/ios/CMakeLists.txt: the iOS app's Xcode project.
#
# Not run by hand: tools/s9/ios_app.py builds every C and C++ part of the app into static archives
# (the player, the renderer and its shader translator, the session's relay and the installer, SDL3,
# SDL_shadercross and SPIRV-Cross, zlib, libpng, zstd) and the game into one prelinked library
# (tools/s9/ios_game.py), writes the app's resources (game.env, tweaks.json, the icon), and then
# configures this project with the Xcode generator:
#
#   cmake -G Xcode -S host/ios -B private/generated/s9/ios/xcode \
#         -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
#         -DSA2_IOS_BUILD=<the builder's tree> -DSA2_IOS_GAME=<libsa2game.a> [-DSA2_IOS_TEAM=<team id>]
#
# What the project itself compiles: the app's Objective-C++ (host/ios/native: main, the session, the
# console, the in-game menu) and its Swift screens (host/ios/app). Open the .xcodeproj it writes, pick
# a team under Signing (or pass SA2_IOS_TEAM), and run; or let ios_app.py's `ipa` phase make an
# unsigned .ipa for a sideloading tool to sign.
cmake_minimum_required(VERSION 3.24)
project(SA2Recomp LANGUAGES C CXX OBJC OBJCXX Swift)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "host/ios is an iOS project: configure with -G Xcode -DCMAKE_SYSTEM_NAME=iOS")
endif()

set(SA2_IOS_BUILD "" CACHE PATH "tools/s9/ios_app.py's build tree (lib/, sdl3/, shadercross/, gen/)")
set(SA2_IOS_GAME "" CACHE FILEPATH "the prelinked game, libsa2game.a (tools/s9/ios_game.py); empty: an app without the game")
set(SA2_IOS_TEAM "" CACHE STRING "the Apple development team that signs the app (empty: choose it in Xcode)")
set(SA2_IOS_BUNDLE_ID "com.sa2recomp.ios" CACHE STRING "the app's bundle identifier")
set(SA2_IOS_VERSION "0.1" CACHE STRING "CFBundleShortVersionString")
set(SA2_IOS_BUILD_NUMBER "1" CACHE STRING "CFBundleVersion")
option(SA2_IOS_INCREASED_MEMORY "ask for com.apple.developer.kernel.increased-memory-limit (a paid team's entitlement)" OFF)

if(NOT SA2_IOS_BUILD OR NOT EXISTS "${SA2_IOS_BUILD}/lib/libsa2_player.a")
    message(FATAL_ERROR "SA2_IOS_BUILD (${SA2_IOS_BUILD}) holds no lib/libsa2_player.a: run tools/s9/ios_app.py")
endif()

set(B "${SA2_IOS_BUILD}")
set(HOST "${CMAKE_CURRENT_SOURCE_DIR}/..")

set(NATIVE
    native/sa2_ios_main.mm
    native/sa2_ios_session.mm
    native/sa2_ios_console.mm
    native/sa2_ios_ingame.mm
    native/sa2_ios_prof.mm)
set(SWIFT
    app/Launcher.swift
    app/AppModel.swift
    app/GameSettings.swift
    app/Tweaks.swift
    app/HomeView.swift
    app/SettingsViews.swift
    app/ControlsView.swift
    app/DebugView.swift)
set(RESOURCES
    "${B}/gen/app/game.env"
    "${B}/gen/app/tweaks.json"
    "${B}/gen/app/Assets.xcassets"
    "${B}/gen/app/Licenses"
    LaunchScreen.storyboard)

add_executable(SA2Recomp MACOSX_BUNDLE ${NATIVE} ${SWIFT} ${RESOURCES} app/Bridge.h lldbinit)
# Xcode's Copy Bundle Resources phase: the asset catalog through actool, the storyboard through ibtool.
set_target_properties(SA2Recomp PROPERTIES RESOURCE "${RESOURCES}")

# These become the target's HEADER_SEARCH_PATHS in Xcode, for Objective-C++ and for the Swift
# bridging header alike; setting XCODE_ATTRIBUTE_HEADER_SEARCH_PATHS as well would replace them.
target_include_directories(SA2Recomp PRIVATE
    native
    "${HOST}/launch"
    "${HOST}/install"
    "${HOST}/player"
    "${B}/sdl3/include")
target_compile_options(SA2Recomp PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-std=c++17 -fobjc-arc -Wall -Wno-unused-parameter>
    $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>)

set(LIBS
    "${B}/lib/libsa2_player.a"
    "${B}/lib/libsa2_host.a"
    "${B}/lib/libsa2_d3d9gpu.a"
    "${B}/lib/libd9g_shader.a"
    "${B}/lib/libdxbc_spv.a"
    "${B}/shadercross/lib/libSDL3_shadercross.a"
    "${B}/shadercross/lib/libspirv-cross-c.a"
    "${B}/shadercross/lib/libspirv-cross-msl.a"
    "${B}/shadercross/lib/libspirv-cross-glsl.a"
    "${B}/shadercross/lib/libspirv-cross-hlsl.a"
    "${B}/shadercross/lib/libspirv-cross-reflect.a"
    "${B}/shadercross/lib/libspirv-cross-cpp.a"
    "${B}/shadercross/lib/libspirv-cross-util.a"
    "${B}/shadercross/lib/libspirv-cross-core.a"
    "${B}/sdl3/lib/libSDL3.a"
    "${B}/deps/libpng.a"
    "${B}/deps/libz.a"
    "${B}/deps/libzstd.a")
foreach(lib ${LIBS})
    if(NOT EXISTS "${lib}")
        message(FATAL_ERROR "${lib} is missing: run tools/s9/ios_app.py")
    endif()
endforeach()
if(SA2_IOS_GAME)
    if(NOT EXISTS "${SA2_IOS_GAME}")
        message(FATAL_ERROR "SA2_IOS_GAME (${SA2_IOS_GAME}) does not exist: run tools/s9/ios_game.py link")
    endif()
    list(PREPEND LIBS "${SA2_IOS_GAME}")
else()
    # An app without the game (the build's own check): a stand-in that refuses to start.
    target_sources(SA2Recomp PRIVATE native/sa2_ios_nogame.c)
endif()

target_link_libraries(SA2Recomp PRIVATE
    ${LIBS}
    "-framework AVFoundation" "-framework AudioToolbox" "-framework CoreAudio" "-framework CoreBluetooth"
    "-framework CoreFoundation" "-framework CoreGraphics" "-framework CoreHaptics" "-framework CoreMotion"
    "-framework CoreText" "-framework Foundation" "-framework GameController" "-framework Metal"
    "-framework QuartzCore" "-framework UIKit" "-framework UniformTypeIdentifiers"
    # SDL's scene delegate is named only by Info.plist: -ObjC loads every Objective-C class of the archives.
    -ObjC)

set(ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/SA2Recomp.entitlements")
if(SA2_IOS_INCREASED_MEMORY)
    set(ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/SA2Recomp-increased-memory.entitlements")
endif()

set_target_properties(SA2Recomp PROPERTIES
    OUTPUT_NAME "SA2Recomp"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${SA2_IOS_BUNDLE_ID}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${SA2_IOS_VERSION}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${SA2_IOS_BUILD_NUMBER}"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${SA2_IOS_BUNDLE_ID}"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/app/Bridge.h"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
    XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++17"
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${ENTITLEMENTS}"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${SA2_IOS_TEAM}"
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
    XCODE_ATTRIBUTE_DEAD_CODE_STRIPPING "YES"
    XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS "YES"
    XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT "dwarf-with-dsym"
    # The game's lifted code is one object far larger than an app's usual code; the linker's
    # warnings about it are not errors.
    XCODE_ATTRIBUTE_OTHER_LDFLAGS "$(inherited) -Wl,-no_warn_duplicate_libraries"
    # A debugging session: the runtime catches its own faults (runtime/sa2_trap.c); lldb is told to
    # let them through (host/ios/lldbinit, which the scheme's launch action sources).
    XCODE_GENERATE_SCHEME ON
    XCODE_SCHEME_LLDB_INIT_FILE "${CMAKE_CURRENT_SOURCE_DIR}/lldbinit"
    XCODE_SCHEME_ENVIRONMENT "OS_ACTIVITY_DT_MODE=YES")
