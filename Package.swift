// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenJBL",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JBLKit", targets: ["JBLKit"]),
        .library(name: "JBLBluetooth", targets: ["JBLBluetooth"]),
        .executable(name: "jbl-probe", targets: ["jbl-probe"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "JBLKit"),
        .target(name: "JBLBluetooth", dependencies: ["JBLKit"],
                linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreBluetooth")]),
        .executableTarget(name: "jbl-probe", dependencies: [
            "JBLKit", "JBLBluetooth", .product(name: "ArgumentParser", package: "swift-argument-parser")
        ], exclude: ["Info.plist"], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                          "-Xlinker", "Sources/jbl-probe/Info.plist"])
        ]),
        .testTarget(name: "JBLKitTests", dependencies: ["JBLKit"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
