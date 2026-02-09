// swift-tools-version: 6.1
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Yrden",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "Yrden", targets: ["Yrden"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm/", from: "2.30.0"),
        .package(url: "https://github.com/huggingface/swift-jinja.git", from: "2.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.1.6"),
        .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.7964.0")),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.3.0"),
    ],
    targets: [
        .target(
            name: "Yrden",
            dependencies: [
                "YrdenMacros",
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSBedrock", package: "aws-sdk-swift"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .macro(
            name: "YrdenMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "YrdenTestSupport",
            dependencies: ["Yrden"],
            path: "Tests/YrdenTestSupport"
        ),
        .testTarget(
            name: "YrdenTests",
            dependencies: ["Yrden", "YrdenTestSupport"]
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
        .executableTarget(
            name: "MCPOAuthTest",
            dependencies: ["Yrden"],
            path: "Examples/MCPOAuthTest"
        ),
        .executableTarget(
            name: "MCPOAuthApp",
            dependencies: ["Yrden"],
            path: "Examples/MCPOAuthApp",
            exclude: ["Info.plist", "build-app.sh"]
        ),
        .executableTarget(
            name: "YrdenExample",
            dependencies: ["Yrden"],
            path: "Examples/YrdenExample",
            exclude: ["build-app.sh"]
        ),
        .executableTarget(
            name: "AgentCLI",
            dependencies: ["Yrden"],
            path: "Examples/AgentCLI"
        ),
        .executableTarget(
            name: "BugBash",
            dependencies: ["Yrden"],
            path: "Examples/BugBash",
            exclude: ["scenarios", "scripts", "results", "findings"]
        ),
        .executableTarget(
            name: "MLXExploration",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Jinja", package: "swift-jinja"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Examples/MLXExploration"
        ),
        .executableTarget(
            name: "GGMLExploration",
            dependencies: [
                .product(name: "LlamaSwift", package: "llama.swift"),
                .product(name: "Jinja", package: "swift-jinja"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Examples/GGMLExploration"
        ),
    ]
)
