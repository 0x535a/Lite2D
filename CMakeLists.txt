cmake_minimum_required(VERSION 3.25)
project(Lite2D LANGUAGES C CXX OBJCXX Swift)
set(LITE2D_OUTPUT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/dist" CACHE PATH "Local app bundle output directory")
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_Swift_LANGUAGE_VERSION 5)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
set(SDK "${CMAKE_CURRENT_SOURCE_DIR}/vendor/CubismNativeSamples")
set(CORE "${SDK}/Core")
set(THIRD "${SDK}/Samples/OpenGL/thirdParty")
if(NOT EXISTS "${CORE}/lib/macos/arm64/libLive2DCubismCore.a")
  message(FATAL_ERROR "Install official Core first: python3 scripts/install_core.py --accept-sdk-license")
endif()
set(BUILD_UTILS OFF CACHE BOOL "" FORCE)
add_subdirectory("${THIRD}/glew/build/cmake" "${CMAKE_BINARY_DIR}/glew")
set(FRAMEWORK_SOURCE OpenGL)
add_subdirectory("${SDK}/Framework" "${CMAKE_BINARY_DIR}/Framework")
target_compile_definitions(Framework PUBLIC CSM_TARGET_MAC_GL)
target_include_directories(Framework PUBLIC "${CORE}/include" "${THIRD}/glew/include")

# R5 uses process singletons for shader/FBO pools. Each Lite2D GL context must
# own them separately. Generate patched build copies; the pinned submodule stays
# intact. No model, physics or masking implementation is replaced.
execute_process(COMMAND python3 "${CMAKE_CURRENT_SOURCE_DIR}/scripts/isolate_gl_contexts.py"
  "${SDK}/Framework" "${CMAKE_BINARY_DIR}/context-isolation" COMMAND_ERROR_IS_FATAL ANY)
get_target_property(FRAMEWORK_SOURCES Framework SOURCES)
foreach(NAME CubismShader_OpenGLES2 CubismOffscreenManager_OpenGLES2)
  list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX "/${NAME}\\.cpp$")
  list(APPEND FRAMEWORK_SOURCES "${CMAKE_BINARY_DIR}/context-isolation/${NAME}.cpp")
endforeach()
set_property(TARGET Framework PROPERTY SOURCES "${FRAMEWORK_SOURCES}")
target_include_directories(Framework PRIVATE "${SDK}/Framework/src/Rendering/OpenGL")
target_link_libraries(Framework PUBLIC "${CORE}/lib/macos/arm64/libLive2DCubismCore.a" glew_s "-framework OpenGL")

add_library(Lite2DEngine STATIC Engine/NativeHost.mm Engine/LegacyHost.mm Bridge/Live2DBridge.mm Bridge/ModelArchive.mm)
target_include_directories(Lite2DEngine PRIVATE Engine Bridge "${THIRD}/stb")
target_compile_options(Lite2DEngine PRIVATE -fobjc-arc -Wno-deprecated-declarations)
target_link_libraries(Lite2DEngine PUBLIC Framework "-framework Foundation" "-framework AppKit" "-framework JavaScriptCore" archive)

file(GLOB APP_SOURCES CONFIGURE_DEPENDS "App/*.swift")
add_executable(Lite2D MACOSX_BUNDLE ${APP_SOURCES})
target_compile_options(Lite2D PRIVATE -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/Bridge/Live2DBridge.h")
target_link_libraries(Lite2D PRIVATE Lite2DEngine "-framework AppKit" "-framework SwiftUI" "-framework QuartzCore" "-framework OpenGL" "-framework ServiceManagement" "-lc++")
set_target_properties(Lite2D PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/App/Info.plist"
  RUNTIME_OUTPUT_DIRECTORY "${LITE2D_OUTPUT_ROOT}")
set_property(TARGET Lite2D APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/legacy-host.js")
file(GLOB_RECURSE LOCALIZATION_FILES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/Localizations/*")
set_property(TARGET Lite2D APPEND PROPERTY LINK_DEPENDS ${LOCALIZATION_FILES})
# Liquid Glass icon (macOS 26/27): actool emits Assets.car for the layered .icon
# plus a flattened AppIcon.icns that macOS 14-25 fall back to. Must precede codesign.
set(APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AppIcon.icon")
file(GLOB_RECURSE APP_ICON_FILES CONFIGURE_DEPENDS "${APP_ICON}/*")
set_property(TARGET Lite2D APPEND PROPERTY LINK_DEPENDS ${APP_ICON_FILES})
add_custom_command(TARGET Lite2D POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:Lite2D>/Contents/Resources"
  COMMAND /usr/bin/xcrun actool "${APP_ICON}" --compile "$<TARGET_BUNDLE_DIR:Lite2D>/Contents/Resources"
    --output-partial-info-plist "${CMAKE_BINARY_DIR}/AppIcon-partial.plist"
    --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO
    --development-region en --target-device mac --platform macosx --minimum-deployment-target 14.0
    --output-format human-readable-text --errors --warnings --notices)
add_custom_command(TARGET Lite2D POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E rm -f "$<TARGET_FILE:Lite2D>.d"
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${SDK}/Framework/src/Rendering/OpenGL/Shaders/Standard" "$<TARGET_BUNDLE_DIR:Lite2D>/Contents/Resources/FrameworkShaders"
  COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/Resources/legacy-host.js" "$<TARGET_BUNDLE_DIR:Lite2D>/Contents/Resources/legacy-host.js"
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/Resources/Localizations" "$<TARGET_BUNDLE_DIR:Lite2D>/Contents/Resources"
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:Lite2D>")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/LegacyRuntime/legacy-core.js")
  set_property(TARGET Lite2D APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/LegacyRuntime/legacy-core.js")
  add_custom_command(TARGET Lite2D PRE_LINK
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:Lite2D>/Contents/Resources"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/Resources/LegacyRuntime/legacy-core.js" "$<TARGET_BUNDLE_DIR:Lite2D>/Contents/Resources/legacy-core.js")
endif()
