import SwiftSyntax
import SwiftSyntaxMacros

/// Peer macro for property descriptions and constraints.
/// This macro doesn't generate any code - it's a marker that the @Schema macro reads.
public struct GuideMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // No code generation - @Guide is just a marker attribute
        // The @Schema macro reads @Guide attributes from properties
        return []
    }
}
