// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PlamoTranslateKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlamoTranslateCore", targets: ["PlamoTranslateCore"]),
        .library(name: "PlamoTranslateKit", targets: ["PlamoTranslateKit"]),
    ],
    targets: [
        // llama.cpp 公式リリースの XCFramework（b12176 に固定）。
        // slice: macos-arm64_x86_64 / ios-arm64（iOS シミュレータ slice は無い）
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12176/llama-b12176-xcframework.zip",
            checksum: "8c2fb75ed30607a8f6fd4af6365d7a68ecd765e0d94d9a297dd313b419feba9c"
        ),
        // 純 Swift（Foundation のみ）。Linux でもビルド・テスト可能。
        .target(
            name: "PlamoTranslateCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "PlamoTranslateKit",
            dependencies: [
                "PlamoTranslateCore",
                .target(name: "llama", condition: .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .testTarget(
            name: "PlamoTranslateCoreTests",
            dependencies: ["PlamoTranslateCore"],
            resources: [.process("Resources")]
        ),
    ]
)
