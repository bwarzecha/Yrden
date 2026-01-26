/// Calculator tool for basic math operations.

import Foundation
import Yrden

/// Calculator tool for performing arithmetic operations.
///
/// Demonstrates a basic synchronous tool with typed arguments.
struct CalculatorTool: AgentTool {
    typealias Deps = AppDependencies
    typealias Args = CalculatorArgs
    typealias Output = String

    var name: String { "calculator" }
    var description: String {
        "Perform basic arithmetic operations. Supports add, subtract, multiply, divide."
    }

    func call(
        context: AgentContext<AppDependencies>,
        arguments: Args
    ) async throws -> ToolResult<String> {
        let result: Double

        switch arguments.operation.lowercased() {
        case "add", "+":
            result = arguments.a + arguments.b
        case "subtract", "sub", "-":
            result = arguments.a - arguments.b
        case "multiply", "mul", "*":
            result = arguments.a * arguments.b
        case "divide", "div", "/":
            guard arguments.b != 0 else {
                return .retry(message: "Cannot divide by zero. Please provide a non-zero divisor.")
            }
            result = arguments.a / arguments.b
        default:
            return .retry(message: "Unknown operation '\(arguments.operation)'. Use add, subtract, multiply, or divide.")
        }

        // Format nicely - no decimals for whole numbers
        let formatted = result.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", result)
            : String(format: "%.4f", result)

        return .success("\(arguments.a) \(arguments.operation) \(arguments.b) = \(formatted)")
    }
}

/// Arguments for the calculator tool.
@Schema(description: "Calculator operation arguments")
struct CalculatorArgs {
    @Guide(description: "First number")
    let a: Double

    @Guide(description: "Second number")
    let b: Double

    @Guide(description: "Operation: add, subtract, multiply, or divide")
    let operation: String
}
