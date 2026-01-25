# AWS Bedrock Provider Implementation Plan

## Overview

Add AWS Bedrock as the third provider, enabling access to Claude, Amazon Nova, Meta Llama, Mistral, and other models through AWS infrastructure.

## Key Differences from Anthropic Direct API

| Aspect | Anthropic Direct | AWS Bedrock |
|--------|------------------|-------------|
| **Auth** | API key header (`x-api-key`) | AWS Signature V4 |
| **Endpoint** | `api.anthropic.com/v1/messages` | `bedrock-runtime.{region}.amazonaws.com/model/{modelId}/converse` |
| **System message** | String field `system` | Array of content blocks `system: [{text: "..."}]` |
| **Tool definition** | `input_schema` | `toolSpec.inputSchema.json` |
| **Streaming endpoint** | Same endpoint, `stream: true` | Different endpoint: `/converseStream` |
| **Stop reasons** | `end_turn`, `tool_use`, `max_tokens` | `end_turn`, `tool_use`, `max_tokens`, `guardrail_intervened`, `content_filtered` |
| **Structured output** | Native (beta) | NOT SUPPORTED - must use tool forcing |
| **Model ID format** | `claude-sonnet-4-5-20250929` | `anthropic.claude-sonnet-4-5-20250929-v1:0` or inference profile ID |

## Architecture Design

### Provider/Model Split

Following our existing pattern:
- `BedrockProvider` - AWS credentials, region, signing
- `BedrockModel` - Converse API format encoding/decoding

```
┌─────────────────────┐     ┌──────────────────┐
│   BedrockProvider   │────▶│   BedrockModel   │
├─────────────────────┤     ├──────────────────┤
│ • credentials       │     │ • name           │
│ • region            │     │ • capabilities   │
│ • authenticate()    │     │ • complete()     │
│ • listModels()      │     │ • stream()       │
└─────────────────────┘     └──────────────────┘
```

### AWS Signature V4 Strategy

**Recommended: Use AWS SDK for Swift**

The AWS SDK handles SigV4 signing, credential refresh, and retry logic:

```swift
import AWSBedrockRuntime

// SDK handles all auth complexity
let client = try BedrockRuntimeClient(region: "us-east-1")
let output = try await client.converse(input: ConverseInput(...))
```

**Alternative: Manual signing** (not recommended)

Manual SigV4 is a 5-step process involving:
1. Canonical request creation
2. String-to-sign construction
3. Signing key derivation (4-level HMAC chain)
4. Signature calculation
5. Authorization header assembly

This is error-prone and doesn't handle credential refresh, STS assume-role, or EKS IRSA.

**Decision: Use AWS SDK for Swift**

Pros:
- Correct SigV4 implementation
- Credential refresh handled (IAM roles, STS, etc.)
- Retry logic built-in
- Maintained by AWS

Cons:
- Large dependency
- Pulls in AWS common packages

We can wrap the SDK types internally and not expose them in our public API.

### Authentication Options

Support two authentication methods:

#### 1. Explicit Credentials (Recommended for local dev)

```swift
let provider = BedrockProvider(
    region: "us-east-1",
    accessKeyId: "AKIA...",
    secretAccessKey: "..."
)
```

#### 2. Default Profile (AWS CLI credentials)

```swift
let provider = BedrockProvider(
    region: "us-east-1",
    profile: "default"  // or nil to use default
)
```

This reads from `~/.aws/credentials` and `~/.aws/config`.

**Important:** Skip EC2 metadata check for local development. The AWS SDK's default credential chain tries EC2 instance metadata which hangs/timeouts on non-EC2 machines. We should:

1. Try explicit credentials first (if provided)
2. Try shared credentials file (`~/.aws/credentials`)
3. Try environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
4. **Skip** EC2/ECS metadata endpoints for local dev

```swift
public struct BedrockProvider: Provider, Sendable {
    private let client: BedrockRuntimeClient

    /// Create with explicit credentials (no network calls)
    public init(
        region: String,
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String? = nil
    ) throws {
        let credentials = StaticAWSCredentialIdentity(
            accessKey: accessKeyId,
            secret: secretAccessKey,
            sessionToken: sessionToken
        )
        let config = try BedrockRuntimeClient.Config(
            region: region,
            credentialsProvider: StaticAWSCredentialIdentityResolver(credentials)
        )
        self.client = BedrockRuntimeClient(config: config)
    }

    /// Create using AWS profile from ~/.aws/credentials
    /// Does NOT check EC2 metadata (safe for local dev)
    public init(
        region: String,
        profile: String? = nil
    ) throws {
        // Use profile-based credentials, skip instance metadata
        let config = try BedrockRuntimeClient.Config(
            region: region,
            credentialsProvider: try ProfileCredentialsProvider(profileName: profile)
        )
        self.client = BedrockRuntimeClient(config: config)
    }
}
```

#### Environment Variables (Alternative)

Also support standard AWS env vars:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN` (optional, for STS)
- `AWS_REGION` or `AWS_DEFAULT_REGION`
- `AWS_PROFILE` (for named profile)

```swift
// Uses env vars if no explicit credentials
let provider = try BedrockProvider.fromEnvironment()
```

## File Structure

```
Sources/Yrden/Providers/Bedrock/
├── BedrockProvider.swift      # Provider with credentials + listModels()
├── BedrockModel.swift         # Model protocol implementation
└── BedrockTypes.swift         # Internal wire format types
```

## Type Mappings

### Yrden → Bedrock Converse

| Yrden Type | Bedrock Type |
|------------|--------------|
| `Message.system(text)` | `system: [{ text: "..." }]` |
| `Message.user([.text(s)])` | `{ role: "user", content: [{ text: "..." }] }` |
| `Message.user([.image(...)])` | `{ role: "user", content: [{ image: { format, source: { bytes } } }] }` |
| `Message.assistant(text)` | `{ role: "assistant", content: [{ text: "..." }] }` |
| `Message.toolResult(id, result)` | `{ role: "user", content: [{ toolResult: { toolUseId, content: [...] } }] }` |
| `ToolDefinition` | `toolConfig.tools[].toolSpec` |
| `CompletionConfig.temperature` | `inferenceConfig.temperature` |
| `CompletionConfig.maxTokens` | `inferenceConfig.maxTokens` |
| `CompletionConfig.stopSequences` | `inferenceConfig.stopSequences` |

### Bedrock → Yrden

| Bedrock Type | Yrden Type |
|--------------|------------|
| `output.message.content[].text` | `CompletionResponse.content` |
| `output.message.content[].toolUse` | `CompletionResponse.toolCalls` |
| `stopReason: "end_turn"` | `StopReason.endTurn` |
| `stopReason: "tool_use"` | `StopReason.toolUse` |
| `stopReason: "max_tokens"` | `StopReason.maxTokens` |
| `stopReason: "guardrail_intervened"` | New: `StopReason.guardrail` |
| `usage.inputTokens` | `Usage.inputTokens` |
| `usage.outputTokens` | `Usage.outputTokens` |

## Structured Output Strategy

**Problem:** Bedrock Converse API has NO native JSON mode.

**Solution:** Use tool forcing (same as Anthropic tool-based approach)

```swift
// For generateWithTool() calls:
let toolConfig = ToolConfig(
    tools: [
        Tool(toolSpec: ToolSpec(
            name: toolName,
            description: description,
            inputSchema: .init(json: schema)
        ))
    ],
    toolChoice: .tool(name: toolName)  // Force this tool
)
```

The model is forced to call the specified tool, and we extract the arguments as the structured output.

**Implication:** `generate()` (native structured output) will NOT work with Bedrock. Users must use `generateWithTool()`.

## Model Discovery

Bedrock has two model identification systems that are closely related:

### 1. Foundation Models (Base IDs)

Foundation models are the base model identifiers:

```
anthropic.claude-haiku-4-5-20251001-v1:0
anthropic.claude-sonnet-4-5-20250929-v1:0
anthropic.claude-opus-4-5-20251101-v1:0
amazon.nova-2-lite-v1:0
amazon.nova-pro-v1:0
meta.llama3-3-70b-instruct-v1:0
```

API: `ListFoundationModels`

### 2. Inference Profiles (Cross-Region Routing)

Inference profiles provide cross-region routing for higher throughput. The ID pattern is:
`{region-prefix}.{foundation-model-id}`

| Prefix | Scope | Example |
|--------|-------|---------|
| `us.` | US regions only | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| `eu.` | EU regions only | `eu.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| `apac.` | Asia-Pacific | `apac.amazon.nova-lite-v1:0` |
| `global.` | All commercial regions | `global.anthropic.claude-opus-4-5-20251101-v1:0` |

**Global profiles are most interesting** - they route to any commercial AWS region for maximum throughput.

API: `ListInferenceProfiles` returns:
```json
{
  "inferenceProfileSummaries": [{
    "inferenceProfileId": "global.anthropic.claude-opus-4-5-20251101-v1:0",
    "inferenceProfileName": "Claude Opus 4.5 (Global)",
    "type": "SYSTEM_DEFINED",
    "status": "ACTIVE",
    "models": [{ "modelArn": "arn:aws:bedrock::foundation-model/anthropic.claude-opus-4-5-20251101-v1:0" }]
  }]
}
```

### Data Model

Return both foundation models and their inference profiles. Each foundation model can have metadata listing its available profiles:

```swift
// Foundation model
ModelInfo(
    id: "anthropic.claude-sonnet-4-5-20250929-v1:0",
    displayName: "Claude Sonnet 4.5",
    metadata: [
        "type": "foundation_model",
        "inferenceProfiles": [
            "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
            "eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
            "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
        ]
    ]
)

// Global inference profile (recommended for production)
ModelInfo(
    id: "global.anthropic.claude-sonnet-4-5-20250929-v1:0",
    displayName: "Claude Sonnet 4.5 (Global)",
    metadata: [
        "type": "inference_profile",
        "profileType": "SYSTEM_DEFINED",
        "baseModel": "anthropic.claude-sonnet-4-5-20250929-v1:0",
        "scope": "global"
    ]
)
```

### Implementation Strategy

1. Call `ListFoundationModels` to get base models
2. Call `ListInferenceProfiles` to get all profiles
3. For each foundation model, attach available profiles as metadata
4. Yield foundation models first, then their inference profiles
5. User can filter by `metadata["type"]` if they only want one kind

## Capability Detection

Different models on Bedrock have different capabilities:

| Model | Tools | Vision | Streaming |
|-------|-------|--------|-----------|
| Claude 4.5 (Opus/Sonnet/Haiku) | Yes | Yes | Yes |
| Claude 4 (Opus/Sonnet) | Yes | Yes | Yes |
| Amazon Nova 2 Lite | Yes | Yes | Yes |
| Amazon Nova Pro/Premier | Yes | Yes | Yes |
| Meta Llama 3.3 | Limited | No | Yes |
| Mistral Large | Yes | No | Yes |

**Implementation:** Detect by model ID prefix:

```swift
static func capabilities(for modelId: String) -> ModelCapabilities {
    // Strip inference profile prefix (us., eu., global., etc.)
    let baseId = modelId.components(separatedBy: ".").dropFirst().joined(separator: ".")

    if baseId.contains("claude") {
        return .claude45  // Full featured
    } else if baseId.contains("nova") {
        return .nova      // Full featured for Nova Pro/Premier/2
    } else if baseId.contains("llama") {
        return .llama     // Limited tools, no vision
    } else if baseId.contains("mistral") {
        return .mistral   // Tools, no vision
    }
    // Default conservative capabilities
    return ModelCapabilities(...)
}
```

**Note:** Need to handle inference profile IDs like `global.anthropic.claude-sonnet-4-5-...` by stripping the prefix.

## Streaming Implementation

Bedrock uses a different endpoint for streaming (`/converseStream`) and returns events via AWS event streams.

Event types:
- `messageStart` - Message begun
- `contentBlockStart` - Content block started
- `contentBlockDelta` - Incremental content
- `contentBlockStop` - Content block ended
- `messageStop` - Message complete
- `metadata` - Token usage

These map closely to Anthropic's events, so our existing `StreamEvent` types work.

## Error Handling

New Bedrock-specific errors to handle:

| Bedrock Error | Yrden Error |
|---------------|-------------|
| `ThrottlingException` | `LLMError.rateLimited` |
| `ValidationException` | `LLMError.invalidRequest` |
| `AccessDeniedException` | `LLMError.invalidAPIKey` (or new auth error) |
| `ModelNotReadyException` | New: `LLMError.modelNotReady` |
| `ModelStreamErrorException` | `LLMError.networkError` |

## Testing Strategy

### Model Selection

Test with two model families to ensure cross-model compatibility:

1. **Claude 4.5 Haiku** (Anthropic via Bedrock)
   - Model: `anthropic.claude-haiku-4-5-20251001-v1:0`
   - Full featured: tools, vision, streaming
   - Cheapest of the Claude 4.5 family

2. **Amazon Nova 2 Lite** (AWS native)
   - Model: `amazon.nova-2-lite-v1:0`
   - Tests AWS-native model handling
   - Supports tools, vision, streaming

### Test Categories

| Category | Description |
|----------|-------------|
| **Unit Tests** | Request/response encoding without API |
| **Auth Tests** | Verify SigV4 signing works |
| **Completion** | Basic text generation |
| **Streaming** | SSE event handling |
| **Tools** | Tool calling flow |
| **Structured Output** | Tool-forced extraction |
| **Multi-turn** | Conversation context |
| **Error Handling** | Throttling, auth failures |

### Environment Variables

```bash
# Required
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1  # or us-west-2

# Optional
AWS_SESSION_TOKEN=...           # For STS temporary credentials
AWS_PROFILE=my-profile          # Named profile from ~/.aws/credentials
```

**Note:** Tests should work with either:
- Explicit env vars (`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`)
- Named profile (`AWS_PROFILE=bedrock-test`)

### Test Gating

Tests require AWS credentials. Skip with clear message if missing:

```swift
@Test func simpleCompletion() async throws {
    guard TestConfig.hasAWSCredentials else {
        throw XCTSkip("AWS credentials not configured")
    }
    // ...
}
```

## Implementation Phases

### Phase 1: Provider Setup

1. Add AWS SDK for Swift dependency to Package.swift
2. Create `BedrockProvider` with credentials handling
3. Implement `authenticate()` (delegates to SDK)
4. Implement `listModels()` using `ListFoundationModels`

**Deliverable:** Provider can list models, validate credentials

### Phase 2: Basic Completion

1. Create `BedrockTypes.swift` with wire format types
2. Implement `BedrockModel` with `complete()` method
3. Add request encoding (Yrden → Converse)
4. Add response decoding (Converse → Yrden)
5. Basic error handling

**Deliverable:** Simple text completion works with Claude + Nova

### Phase 3: Streaming

1. Implement `/converseStream` endpoint handling
2. Parse AWS event stream
3. Map to `StreamEvent` types
4. Handle stream errors

**Deliverable:** Streaming works with Claude + Nova

### Phase 4: Tools & Structured Output

1. Add tool definition encoding
2. Handle tool calls in response
3. Implement tool result encoding
4. Add tool forcing for structured output
5. Wire up `generateWithTool()`

**Deliverable:** `generateWithTool()` works with schemas

### Phase 5: Advanced Features

1. Inference profile support in `listModels()`
2. Vision/image handling
3. Guardrail integration (if needed)
4. Cross-region routing metadata

**Deliverable:** Full feature parity with other providers

### Phase 6: Testing & Documentation

1. Unit tests for types
2. Integration tests (Claude + Nova)
3. Error handling tests
4. Update README with Bedrock examples
5. Update docs/progress.md

**Deliverable:** Production-ready provider

## Dependencies

Add to Package.swift:

```swift
dependencies: [
    // ... existing
    .package(url: "https://github.com/awslabs/aws-sdk-swift", from: "1.0.0"),
],
targets: [
    .target(
        name: "Yrden",
        dependencies: [
            "YrdenMacros",
            .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
        ]
    ),
]
```

**Note:** This adds a significant dependency. Consider:
- Optional Bedrock target for those who don't need AWS
- Or manual SigV4 to avoid SDK dependency (not recommended)

## Open Questions

1. **SDK vs Manual Signing?**
   - Recommendation: SDK (handles complexity)
   - Alternative: Manual (smaller footprint)
   - **Decision: Use SDK** - SigV4 is too complex for manual implementation

2. **Optional Target?**
   - ~~Should Bedrock be a separate product/target?~~
   - **Decision: Bundle together for now** - consider splitting later if needed

3. ~~**Inference Profiles vs Foundation Models?**~~
   - **Decision: List both** - foundation models with their profiles as metadata, plus inference profiles as separate entries with scope info

4. **Cross-Account Assume Role?**
   - Support STS AssumeRole for cross-account?
   - SDK handles this if credentials are configured

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| AWS SDK size | Binary bloat | Optional target |
| SigV4 complexity | Auth bugs | Use SDK |
| Bedrock API changes | Breaking changes | Pin SDK version |
| Regional availability | Model not found | Document regions |
| Credential handling | Security | Follow AWS best practices |

## Success Criteria

1. **Claude completion works** - Text in, text out
2. **Nova completion works** - Same test with Nova model
3. **Streaming works** - Both models stream correctly
4. **Tool calling works** - Define tools, get tool calls back
5. **Structured output works** - `generateWithTool()` returns typed data
6. **Error handling works** - Throttling, auth errors handled
7. **Tests pass** - Unit + integration tests green
8. **Documentation complete** - README updated, examples work

## Timeline Estimate

| Phase | Effort |
|-------|--------|
| Phase 1: Provider Setup | Small |
| Phase 2: Basic Completion | Medium |
| Phase 3: Streaming | Medium |
| Phase 4: Tools & Structured Output | Medium |
| Phase 5: Advanced Features | Small |
| Phase 6: Testing & Documentation | Medium |

---

## Appendix: Available Models (as of January 2026)

### Claude 4.5 Family (Recommended)

| Model ID | Display Name | Notes |
|----------|--------------|-------|
| `anthropic.claude-opus-4-5-20251101-v1:0` | Claude Opus 4.5 | Most capable |
| `anthropic.claude-sonnet-4-5-20250929-v1:0` | Claude Sonnet 4.5 | Balanced |
| `anthropic.claude-haiku-4-5-20251001-v1:0` | Claude Haiku 4.5 | Fast & cheap |

### Claude 4 Family

| Model ID | Display Name |
|----------|--------------|
| `anthropic.claude-opus-4-1-20250805-v1:0` | Claude Opus 4.1 |
| `anthropic.claude-sonnet-4-20250514-v1:0` | Claude Sonnet 4 |

### Amazon Nova Family

| Model ID | Display Name | Notes |
|----------|--------------|-------|
| `amazon.nova-2-lite-v1:0` | Nova 2 Lite | Latest, fast |
| `amazon.nova-premier-v1:0` | Nova Premier | Most capable |
| `amazon.nova-pro-v1:0` | Nova Pro | Balanced |
| `amazon.nova-lite-v1:0` | Nova Lite | Fast & cheap |
| `amazon.nova-micro-v1:0` | Nova Micro | Ultra-fast |

### Global Inference Profiles (Production Recommended)

| Profile ID | Scope |
|------------|-------|
| `global.anthropic.claude-opus-4-5-20251101-v1:0` | Worldwide |
| `global.anthropic.claude-sonnet-4-5-20250929-v1:0` | Worldwide |
| `global.anthropic.claude-haiku-4-5-20251001-v1:0` | Worldwide |
| `global.amazon.nova-2-lite-v1:0` | Worldwide |

---

## Appendix: Bedrock Converse API Reference

### Request Format

```json
{
  "modelId": "anthropic.claude-sonnet-4-5-20250929-v1:0",
  "messages": [
    {
      "role": "user",
      "content": [{ "text": "Hello" }]
    }
  ],
  "system": [
    { "text": "You are helpful." }
  ],
  "inferenceConfig": {
    "maxTokens": 1000,
    "temperature": 0.7,
    "stopSequences": ["\n\nHuman:"]
  },
  "toolConfig": {
    "tools": [
      {
        "toolSpec": {
          "name": "search",
          "description": "Search the web",
          "inputSchema": {
            "json": {
              "type": "object",
              "properties": {
                "query": { "type": "string" }
              },
              "required": ["query"]
            }
          }
        }
      }
    ],
    "toolChoice": { "auto": {} }
  }
}
```

### Response Format

```json
{
  "output": {
    "message": {
      "role": "assistant",
      "content": [
        { "text": "Hello! How can I help?" }
      ]
    }
  },
  "stopReason": "end_turn",
  "usage": {
    "inputTokens": 10,
    "outputTokens": 8
  }
}
```

### Tool Call Response

```json
{
  "output": {
    "message": {
      "role": "assistant",
      "content": [
        {
          "toolUse": {
            "toolUseId": "tooluse_123",
            "name": "search",
            "input": { "query": "Swift programming" }
          }
        }
      ]
    }
  },
  "stopReason": "tool_use"
}
```

### Tool Result Request

```json
{
  "messages": [
    { "role": "user", "content": [{ "text": "Search for Swift" }] },
    {
      "role": "assistant",
      "content": [
        { "toolUse": { "toolUseId": "123", "name": "search", "input": { "query": "Swift" } } }
      ]
    },
    {
      "role": "user",
      "content": [
        {
          "toolResult": {
            "toolUseId": "123",
            "content": [{ "text": "Swift is a programming language..." }]
          }
        }
      ]
    }
  ]
}
```
