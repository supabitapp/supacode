// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CompileTimeProfile",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "CompileTimeProfile",
      targets: ["CompileTimeProfile"]
    ),
    .executable(
      name: "compile-time-profile",
      targets: ["CompileTimeProfileTool"]
    ),
  ],
  targets: [
    .target(
      name: "CompileTimeProfile"
    ),
    .executableTarget(
      name: "CompileTimeProfileTool",
      dependencies: ["CompileTimeProfile"]
    ),
    .testTarget(
      name: "CompileTimeProfileTests",
      dependencies: ["CompileTimeProfile"]
    ),
  ]
)
