# Installation

Yrden is distributed as a Swift package via Swift Package Manager.

## Requirements

- Swift 6.1+
- macOS 15+ or iOS 17+

## Add to Your Project

Add Yrden as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bwarzecha/Yrden.git", from: "0.1.0"),
]
```

Then add it to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Yrden", package: "Yrden"),
    ]
),
```

Import it in your Swift files:

```swift
import Yrden
```

All transitive dependencies (SwiftSyntax, AWS SDK, MCP Swift SDK, swift-subprocess) are resolved automatically.

## API Key Configuration

Yrden supports multiple LLM providers. Set the relevant environment variables for the providers you want to use.

### Anthropic

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

### OpenAI

```bash
export OPENAI_API_KEY=sk-...
```

### AWS Bedrock

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
```

### Local Models (No Keys Required)

Ollama and LM Studio work through the OpenAI-compatible provider and need no API keys. Just start the local server:

```bash
# Ollama
ollama serve

# LM Studio
# Start via the LM Studio app and enable the local server
```

### Using a `.env` File

For convenience during development, store your keys in a `.env` file at the project root:

```bash
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
```

Load them into your shell before running:

```bash
export $(cat .env | grep -v '^#' | xargs)
```

## Running Examples

Yrden ships with executable example targets. Run them with `swift run`:

```bash
# Schema generation (no API key needed)
swift run BasicSchema

# Structured output with real providers (needs API keys)
export $(cat .env | grep -v '^#' | xargs) && swift run StructuredOutput
```

## Running Tests

Unit tests (no API keys required):

```bash
swift test
```

Integration tests with real providers (requires API keys):

```bash
export $(cat .env | grep -v '^#' | xargs) && swift test
```

Run tests for a specific provider:

```bash
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "OpenAI"
export $(cat .env | grep -v '^#' | xargs) && swift test --filter "Anthropic"
```
