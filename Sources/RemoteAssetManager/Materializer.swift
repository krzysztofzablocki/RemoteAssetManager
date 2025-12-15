import Foundation

public struct Materializer<Asset>: Sendable {
    public let closure: @Sendable (Data) throws -> Asset

    public init(closure: @escaping @Sendable (Data) throws -> Asset) {
        self.closure = closure
    }

    public func callAsFunction(_ data: Data) throws -> Asset {
        try closure(data)
    }
}

public struct NotMaterializable: Error, Sendable {
    public init() {}
}
