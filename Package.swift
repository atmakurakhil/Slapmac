// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlapShift",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SlapShift",
            path: "Sources/SlapShift",
            resources: [
                .copy("Resources/Fonts")
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("Combine"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
