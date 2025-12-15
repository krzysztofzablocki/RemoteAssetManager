import Foundation

public struct RemoteAssetCacheHeaders: Codable, Equatable, Sendable {
    public var etag: String?
    public var lastModified: String?

    public init(etag: String? = nil, lastModified: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
    }
}

public struct RemoteAssetFetchResult: Sendable {
    /// `nil` means "not modified" (e.g. HTTP 304).
    public var data: Data?
    public var cacheHeaders: RemoteAssetCacheHeaders

    public init(data: Data?, cacheHeaders: RemoteAssetCacheHeaders) {
        self.data = data
        self.cacheHeaders = cacheHeaders
    }
}

public enum RemoteAssetFetchError: Error, Sendable {
    case nonHTTPResponse
    case invalidStatusCode(Int)
}

public protocol RemoteAssetFetching: Sendable {
    func fetch(url: URL, cacheHeaders: RemoteAssetCacheHeaders) async throws -> RemoteAssetFetchResult
}

public struct URLSessionRemoteAssetFetcher: RemoteAssetFetching {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(url: URL, cacheHeaders: RemoteAssetCacheHeaders) async throws -> RemoteAssetFetchResult {
        let request = Self.makeURLRequest(url: url, cacheHeaders: cacheHeaders)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteAssetFetchError.nonHTTPResponse
        }

        let updatedHeaders = RemoteAssetCacheHeaders(
            etag: httpResponse.value(forHTTPHeaderField: "ETag") ?? cacheHeaders.etag,
            lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified") ?? cacheHeaders.lastModified
        )

        switch httpResponse.statusCode {
        case 200..<300:
            return RemoteAssetFetchResult(data: data, cacheHeaders: updatedHeaders)
        case 304:
            return RemoteAssetFetchResult(data: nil, cacheHeaders: updatedHeaders)
        default:
            throw RemoteAssetFetchError.invalidStatusCode(httpResponse.statusCode)
        }
    }

    static func makeURLRequest(url: URL, cacheHeaders: RemoteAssetCacheHeaders) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60)

        if let etag = cacheHeaders.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        if let lastModified = cacheHeaders.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        return request
    }
}
