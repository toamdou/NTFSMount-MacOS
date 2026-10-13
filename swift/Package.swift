// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NTFSMount",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NTFSMount", targets: ["NTFSMount"]),
        .library(name: "NTFSMountCore", targets: ["NTFSMountCore"]),
        .library(name: "NTFSMountFinderBridge", targets: ["NTFSMountFinderBridge"]),
    ],
    targets: [
        // 语言包放在 Core（Localization 类在 Core）：资源若跟着 UI 走，
        // Core 单独链接时取不到文案，界面会变成裸 key 而代码不报错。
        .target(
            name: "NTFSMountCore",
            path: "Sources/NTFSMountCore",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NTFSMountUI",
            dependencies: ["NTFSMountCore"],
            path: "Sources/NTFSMountUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NTFSMountFinderBridge",
            dependencies: ["NTFSMountCore"],
            path: "Sources/NTFSMountFinderBridge",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Finder 扩展 appex：SwiftPM 产不出 .appex bundle（入口是 Info.plist 的
        // NSExtensionPrincipalClass，没有 main），故这里声明为 library 仅供验证。
        .target(
            name: "NTFSMountFinderSync",
            dependencies: ["NTFSMountFinderBridge"],
            path: "Sources/NTFSMountFinderSync",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("FinderSync")
            ]
        ),
        .executableTarget(
            name: "NTFSMountSmoke",
            dependencies: ["NTFSMountCore"],
            path: "Sources/NTFSMountSmoke",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "NTFSMount",
            dependencies: ["NTFSMountCore", "NTFSMountUI", "NTFSMountFinderBridge"],
            path: "Sources/NTFSMount",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
