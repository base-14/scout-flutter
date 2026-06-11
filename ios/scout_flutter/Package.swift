// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "scout_flutter",
  platforms: [.iOS("12.0")],
  products: [
    .library(name: "scout-flutter", targets: ["scout_flutter"])
  ],
  dependencies: [
    .package(url: "https://github.com/kstenerud/KSCrash.git", from: "2.0.0")
  ],
  targets: [
    .target(
      name: "scout_flutter",
      dependencies: [
        .product(name: "Recording", package: "KSCrash"),
        .product(name: "Installations", package: "KSCrash")
      ],
      path: "Sources/scout_flutter"
    )
  ]
)
