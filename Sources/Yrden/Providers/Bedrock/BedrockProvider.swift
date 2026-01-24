/// AWS Bedrock provider for authentication and connection.
///
/// Handles:
/// - AWS credentials (explicit, profile-based, or environment)
/// - Region configuration
/// - Model and inference profile discovery
///
/// ## Usage
/// ```swift
/// // Option 1: Explicit credentials
/// let provider = try BedrockProvider(
///     region: "us-east-1",
///     accessKeyId: "AKIA...",
///     secretAccessKey: "..."
/// )
///
/// // Option 2: Named profile from ~/.aws/credentials
/// let provider = try BedrockProvider(
///     region: "us-east-1",
///     profile: "default"
/// )
///
/// // Option 3: Environment variables
/// let provider = try BedrockProvider.fromEnvironment()
///
/// let model = BedrockModel(name: "anthropic.claude-haiku-4-5-20251001-v1:0", provider: provider)
/// let response = try await model.complete("Hello!")
/// ```

import Foundation
@preconcurrency import AWSBedrockRuntime
@preconcurrency import AWSBedrock
import AWSClientRuntime
import AWSSDKIdentity
import Smithy
import SmithyIdentity

// MARK: - BedrockProvider

/// Provider for AWS Bedrock Runtime API.
///
/// Configures authentication and connection details for Bedrock:
/// - AWS credentials via explicit keys, profile, or environment
/// - Region configuration
/// - Model discovery via ListFoundationModels and ListInferenceProfiles
///
/// Note: Uses `@unchecked Sendable` because the AWS SDK clients are thread-safe
/// but don't formally conform to Sendable.
public struct BedrockProvider: Provider, @unchecked Sendable {
    /// AWS region for Bedrock API calls.
    public let region: String

    /// Internal Bedrock Runtime client for model invocation.
    internal let runtimeClient: BedrockRuntimeClient

    /// Internal Bedrock client for model discovery.
    internal let bedrockClient: BedrockClient

    /// Base URL for API requests (not used directly - SDK handles endpoints).
    public var baseURL: URL {
        URL(string: "https://bedrock-runtime.\(region).amazonaws.com")!
    }

    // MARK: - Initializers

    /// Creates a provider with explicit AWS credentials.
    ///
    /// This is the recommended approach for local development as it avoids
    /// network calls to EC2 metadata services.
    ///
    /// - Parameters:
    ///   - region: AWS region (e.g., "us-east-1")
    ///   - accessKeyId: AWS access key ID
    ///   - secretAccessKey: AWS secret access key
    ///   - sessionToken: Optional session token for temporary credentials
    public init(
        region: String,
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String? = nil
    ) throws {
        self.region = region

        let credentials = AWSCredentialIdentity(
            accessKey: accessKeyId,
            secret: secretAccessKey,
            sessionToken: sessionToken
        )
        let resolver = try StaticAWSCredentialIdentityResolver(credentials)

        let runtimeConfig = try BedrockRuntimeClient.Config(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        self.runtimeClient = BedrockRuntimeClient(config: runtimeConfig)

        let bedrockConfig = try BedrockClient.Config(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        self.bedrockClient = BedrockClient(config: bedrockConfig)
    }

    /// Creates a provider using an AWS profile from ~/.aws/credentials.
    ///
    /// This does NOT check EC2 instance metadata, making it safe for local development
    /// without network timeouts.
    ///
    /// - Parameters:
    ///   - region: AWS region (e.g., "us-east-1")
    ///   - profile: Profile name (defaults to "default")
    public init(
        region: String,
        profile: String = "default"
    ) throws {
        self.region = region

        // Use profile-based credentials - does not hit EC2 metadata
        let resolver = try ProfileAWSCredentialIdentityResolver(profileName: profile)

        let runtimeConfig = try BedrockRuntimeClient.Config(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        self.runtimeClient = BedrockRuntimeClient(config: runtimeConfig)

        let bedrockConfig = try BedrockClient.Config(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        self.bedrockClient = BedrockClient(config: bedrockConfig)
    }

    /// Creates a provider from environment variables.
    ///
    /// Reads credentials from:
    /// - `AWS_ACCESS_KEY_ID`
    /// - `AWS_SECRET_ACCESS_KEY`
    /// - `AWS_SESSION_TOKEN` (optional)
    /// - `AWS_REGION` or `AWS_DEFAULT_REGION`
    /// - `AWS_PROFILE` (falls back to profile-based if no keys)
    ///
    /// - Returns: Configured provider
    /// - Throws: If required environment variables are missing
    public static func fromEnvironment() throws -> BedrockProvider {
        let env = ProcessInfo.processInfo.environment

        // Get region (required)
        guard let region = env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"] else {
            throw LLMError.invalidAPIKey // TODO: Better error type
        }

        // Try explicit credentials first
        if let accessKey = env["AWS_ACCESS_KEY_ID"],
           let secretKey = env["AWS_SECRET_ACCESS_KEY"] {
            return try BedrockProvider(
                region: region,
                accessKeyId: accessKey,
                secretAccessKey: secretKey,
                sessionToken: env["AWS_SESSION_TOKEN"]
            )
        }

        // Fall back to profile
        let profile = env["AWS_PROFILE"] ?? "default"
        return try BedrockProvider(region: region, profile: profile)
    }

    // MARK: - Provider Protocol

    /// Adds authentication to a request.
    ///
    /// Note: For Bedrock, authentication is handled internally by the AWS SDK.
    /// This method is provided for protocol conformance.
    public func authenticate(_ request: inout URLRequest) async throws {
        // AWS SDK handles SigV4 signing internally
        // This is not used for Bedrock - we call the SDK directly
    }

    /// Lists available models and inference profiles from Bedrock.
    ///
    /// Returns a lazy stream of model information including:
    /// - Foundation models (base model IDs)
    /// - Inference profiles (cross-region routing)
    ///
    /// Each entry includes metadata indicating the type and related profiles.
    ///
    /// ## Usage
    /// ```swift
    /// // List all available models
    /// for try await model in provider.listModels() {
    ///     print("\(model.displayName): \(model.id)")
    /// }
    ///
    /// // Find global inference profiles only
    /// for try await model in provider.listModels() {
    ///     if model.metadata?["scope"]?.stringValue == "global" {
    ///         print(model.id)
    ///     }
    /// }
    /// ```
    ///
    /// - Returns: Stream of available models and inference profiles
    public func listModels() -> AsyncThrowingStream<ModelInfo, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Collect inference profiles first (we'll need them for metadata)
                    var profilesByModel: [String: [String]] = [:]
                    var allProfiles: [ModelInfo] = []

                    // Fetch inference profiles
                    var profileNextToken: String? = nil
                    repeat {
                        let profileInput = ListInferenceProfilesInput(
                            maxResults: 100,
                            nextToken: profileNextToken
                        )
                        let profileOutput = try await self.bedrockClient.listInferenceProfiles(input: profileInput)

                        for profile in profileOutput.inferenceProfileSummaries ?? [] {
                            guard let profileId = profile.inferenceProfileId,
                                  let profileName = profile.inferenceProfileName else {
                                continue
                            }

                            // Extract base model from ARN
                            let baseModel = self.extractBaseModelId(from: profile.models ?? [])

                            // Determine scope from ID prefix
                            let scope = self.inferenceProfileScope(from: profileId)

                            // Track profiles by base model
                            if let base = baseModel {
                                profilesByModel[base, default: []].append(profileId)
                            }

                            let profileInfo = ModelInfo(
                                id: profileId,
                                displayName: profileName,
                                createdAt: nil,
                                metadata: [
                                    "type": "inference_profile",
                                    "profileType": .string(profile.type?.rawValue ?? "UNKNOWN"),
                                    "status": .string(profile.status?.rawValue ?? "UNKNOWN"),
                                    "baseModel": baseModel.map { .string($0) } ?? .null,
                                    "scope": .string(scope)
                                ]
                            )
                            allProfiles.append(profileInfo)
                        }

                        profileNextToken = profileOutput.nextToken
                    } while profileNextToken != nil

                    // Fetch foundation models
                    let modelsInput = ListFoundationModelsInput()
                    let modelsOutput = try await self.bedrockClient.listFoundationModels(input: modelsInput)

                    for model in modelsOutput.modelSummaries ?? [] {
                        guard let modelId = model.modelId,
                              let modelName = model.modelName else {
                            continue
                        }

                        // Get inference profiles for this model
                        let profiles = profilesByModel[modelId] ?? []

                        let modelInfo = ModelInfo(
                            id: modelId,
                            displayName: modelName,
                            createdAt: nil,
                            metadata: [
                                "type": "foundation_model",
                                "provider": .string(model.providerName ?? "unknown"),
                                "inferenceProfiles": .array(profiles.map { .string($0) }),
                                "inputModalities": .array((model.inputModalities ?? []).map { .string($0.rawValue) }),
                                "outputModalities": .array((model.outputModalities ?? []).map { .string($0.rawValue) })
                            ]
                        )
                        continuation.yield(modelInfo)
                    }

                    // Yield inference profiles after foundation models
                    for profile in allProfiles {
                        continuation.yield(profile)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: self.mapError(error))
                }
            }
        }
    }

    // MARK: - Helper Methods

    /// Extracts the base model ID from inference profile model ARNs.
    private func extractBaseModelId(from models: [BedrockClientTypes.InferenceProfileModel]) -> String? {
        guard let firstModel = models.first,
              let arn = firstModel.modelArn else {
            return nil
        }
        // ARN format: arn:aws:bedrock::foundation-model/anthropic.claude-...
        if let range = arn.range(of: "foundation-model/") {
            return String(arn[range.upperBound...])
        }
        return nil
    }

    /// Determines the scope of an inference profile from its ID.
    private func inferenceProfileScope(from profileId: String) -> String {
        if profileId.hasPrefix("global.") {
            return "global"
        } else if profileId.hasPrefix("us.") {
            return "us"
        } else if profileId.hasPrefix("eu.") {
            return "eu"
        } else if profileId.hasPrefix("apac.") {
            return "apac"
        }
        return "regional"
    }

    /// Maps AWS SDK errors to LLMError.
    internal func mapError(_ error: Error) -> LLMError {
        // Check for common AWS error types
        let errorDescription = String(describing: error)

        if errorDescription.contains("AccessDenied") ||
           errorDescription.contains("UnauthorizedException") {
            return .invalidAPIKey
        }

        if errorDescription.contains("ThrottlingException") ||
           errorDescription.contains("TooManyRequestsException") {
            return .rateLimited(retryAfter: nil)
        }

        if errorDescription.contains("ValidationException") {
            return .invalidRequest(errorDescription)
        }

        if errorDescription.contains("ModelNotReadyException") {
            return .serverError("Model not ready: \(errorDescription)")
        }

        if errorDescription.contains("ResourceNotFoundException") {
            return .modelNotFound(errorDescription)
        }

        return .networkError(errorDescription)
    }
}
