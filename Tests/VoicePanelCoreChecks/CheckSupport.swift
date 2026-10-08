import Foundation

struct CheckCase: Sendable {
    let name: String
    let body: @Sendable () throws -> Void
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@inline(__always)
func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String
) throws {
    guard condition() else {
        throw CheckFailure(description: message())
    }
}

@inline(__always)
func expectEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ context: String = ""
) throws {
    let actualValue = actual()
    let expectedValue = expected()
    guard actualValue == expectedValue else {
        let prefix = context.isEmpty ? "" : "\(context): "
        throw CheckFailure(
            description:
                "\(prefix)expected \(String(describing: expectedValue)), got \(String(describing: actualValue))"
        )
    }
}

@inline(__always)
func expectApproximatelyEqual(
    _ actual: Double,
    _ expected: Double,
    accuracy: Double,
    _ context: String = ""
) throws {
    guard abs(actual - expected) <= accuracy else {
        let prefix = context.isEmpty ? "" : "\(context): "
        throw CheckFailure(
            description: "\(prefix)expected \(expected) ± \(accuracy), got \(actual)"
        )
    }
}
