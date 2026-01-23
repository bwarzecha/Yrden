// swift-tools-version: 6.0
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Yrden",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Yrden", targets: ["Yrden"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "Yrden",
            dependencies: ["YrdenMacros"]
        ),
        .macro(
            name: "YrdenMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "YrdenTests",
            dependencies: ["Yrden"]
        ),
        .testTarget(
            name: "YrdenMacrosTests",
            dependencies: [
                "YrdenMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),

        // MARK: - Examples

        .executableTarget(
            name: "BasicSchema",
            dependencies: ["Yrden"],
            path: "Examples/BasicSchema"
        ),
        .executableTarget(
            name: "StructuredOutput",
            dependencies: ["Yrden"],
            path: "Examples/StructuredOutput"
        ),
    ]
)
