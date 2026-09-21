cmake_minimum_required(VERSION 3.30)

project(PlankVision LANGUAGES Swift)

set(CMAKE_Swift_LANGUAGE_VERSION 6)

add_executable(PlankVision MACOSX_BUNDLE
    Sources/PlankVisionApp.swift
    Sources/Models/HostBookmark.swift
    Sources/Services/HostDiscovery.swift
    Sources/Services/HostStore.swift
    Sources/Services/PlankCoreClient.swift
    Sources/Views/AddHostView.swift
    Sources/Views/HostBrowserView.swift
    Sources/Views/HostDetailView.swift
    Sources/Views/SettingsView.swift
)

set_target_properties(PlankVision PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/PlankVision.entitlements"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "A35K7XX2Q6"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "la.instinctual.PLANK.Vision"
    XCODE_ATTRIBUTE_PRODUCT_NAME "PLANK"
    XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE "NO"
    XCODE_ATTRIBUTE_INFOPLIST_KEY_UIApplicationSceneManifest_Generation "YES"
    XCODE_ATTRIBUTE_MARKETING_VERSION "0.1.0"
    XCODE_ATTRIBUTE_CURRENT_PROJECT_VERSION "1"
    XCODE_ATTRIBUTE_SWIFT_STRICT_CONCURRENCY "complete"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "7"
)

