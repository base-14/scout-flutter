// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "scout_flutter",
  platforms: [.iOS("13.0")],
  products: [
    .library(name: "scout-flutter", targets: ["scout_flutter"])
  ],
  dependencies: [
    .package(name: "Scout", path: "/Users/nimishgj/github/scout-android-again/scout-ios")
  ],
  targets: [
    .target(
      name: "scout_flutter",
      dependencies: [
        .product(name: "Scout", package: "Scout"),
        .product(name: "ScoutNative", package: "Scout")
      ],
      path: "Sources/scout_flutter"
    )
  ]
)
