// swift-tools-version: 6.0
import PackageDescription

// MeetingFocusCore is SwiftPM; the app and the diagnostic tool are not.
//
// The point of the split is the developer loop: this library has no dependencies and no platform
// APIs, so `swift test` runs the whole suite in seconds, where the equivalent `xcodebuild test`
// spent well over a minute spinning up a test host for logic that needs none.
let package = Package(
  name: "MeetingFocus",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "MeetingFocusCore", targets: ["MeetingFocusCore"]),
  ],
  targets: [
    .target(name: "MeetingFocusCore"),
    .testTarget(name: "MeetingFocusCoreTests", dependencies: ["MeetingFocusCore"]),
    // Depends on nothing: it reads the app's Swift sources and its String Catalogue from disk as
    // text, so it needs no test host and cannot be broken by a change to what the app links.
    .testTarget(name: "LocalizationTests"),
  ]
)
