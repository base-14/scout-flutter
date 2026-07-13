// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "scout_flutter",
  platforms: [.iOS("13.0")],
  products: [
    .library(name: "scout-flutter", targets: ["scout_flutter"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/base-14/scout-kotlin-multiplatform.git",
      revision: "ios-0.1.4"
    )
  ],
  targets: [
    .target(
      name: "scout_flutter",
      dependencies: [
        .product(name: "Scout", package: "scout-kotlin-multiplatform"),
        .product(name: "ScoutNative", package: "scout-kotlin-multiplatform")
      ],
      path: "Sources/scout_flutter"
    )
  ]
)
