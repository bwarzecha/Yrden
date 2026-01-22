import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct YrdenMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SchemaMacro.self,
    ]
}
