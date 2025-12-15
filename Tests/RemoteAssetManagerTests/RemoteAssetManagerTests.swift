import Foundation
@testable import RemoteAssetManager
import Testing

@Suite
struct RemoteAssetManagerTests {
    @Test
    func loadsFromBundleIntoCache() async throws {
        let temp = try Self.makeTempDir()
        let cacheDir = temp.appendingPathComponent("cache", isDirectory: true)
        let base = temp.appendingPathComponent("base.txt")
        try Data("base".utf8).write(to: base)

        let manager = try await RemoteAssetManager(
            baseAsset: base,
            remoteAsset: try Self.remoteURL(),
            materialize: .init { try Self.utf8String($0) },
            fetcher: MockFetcher { _, _ in .init(data: nil, cacheHeaders: .init()) },
            cacheDirectory: cacheDir,
            cacheFileName: "base.txt",
            appVersion: "1"
        )

        let asset = await manager.asset
        #expect(asset == "base")
        #expect(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("base.txt").path))
    }

    @Test
    func refreshUpdatesAssetOn200() async throws {
        let temp = try Self.makeTempDir()
        let cacheDir = temp.appendingPathComponent("cache", isDirectory: true)
        let base = temp.appendingPathComponent("base.txt")
        try Data("base".utf8).write(to: base)

        let fetcher = MockFetcher { _, _ in
            .init(
                data: Data("remote".utf8),
                cacheHeaders: .init(etag: "\"v1\"", lastModified: "Sat, 01 Jan 2000 00:00:00 GMT")
            )
        }

        let manager = try await RemoteAssetManager(
            baseAsset: base,
            remoteAsset: try Self.remoteURL(),
            materialize: .init { try Self.utf8String($0) },
            fetcher: fetcher,
            cacheDirectory: cacheDir,
            cacheFileName: "base.txt",
            appVersion: "1"
        )

        let outcome = try await manager.refresh()
        #expect(outcome == .updated)

        let asset = await manager.asset
        #expect(asset == "remote")

        let metadataURL = cacheDir.appendingPathComponent("base.txt.metadata.json")
        let metadata = try JSONDecoder().decode(RemoteAssetMetadata.self, from: Data(contentsOf: metadataURL))
        #expect(metadata.cacheHeaders.etag == "\"v1\"")
        #expect(metadata.cacheHeaders.lastModified == "Sat, 01 Jan 2000 00:00:00 GMT")
    }

    @Test
    func refreshDoesNotOverwriteOnNotModified() async throws {
        let temp = try Self.makeTempDir()
        let cacheDir = temp.appendingPathComponent("cache", isDirectory: true)
        let base = temp.appendingPathComponent("base.txt")
        try Data("base".utf8).write(to: base)

        let fetcher = SequenceFetcher(outcomes: [
            .init(data: Data("remote".utf8), cacheHeaders: .init(etag: "\"v1\"")),
            .init(data: nil, cacheHeaders: .init(etag: "\"v1\"")),
        ])

        let manager = try await RemoteAssetManager(
            baseAsset: base,
            remoteAsset: try Self.remoteURL(),
            materialize: .init { try Self.utf8String($0) },
            fetcher: fetcher,
            cacheDirectory: cacheDir,
            cacheFileName: "base.txt",
            appVersion: "1"
        )

        let first = try await manager.refresh()
        #expect(first == .updated)
        #expect(await manager.asset == "remote")

        let second = try await manager.refresh()
        #expect(second == .notModified)
        #expect(await manager.asset == "remote")

        let cachedData = try Data(contentsOf: cacheDir.appendingPathComponent("base.txt"))
        #expect(try Self.utf8String(cachedData) == "remote")
    }

    @Test
    func urlSessionRequestUsesConditionalHeaders() throws {
        let url = try Self.remoteURL()
        let request = URLSessionRemoteAssetFetcher.makeURLRequest(
            url: url,
            cacheHeaders: .init(etag: "\"abc\"", lastModified: "Sat, 01 Jan 2000 00:00:00 GMT")
        )

        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "Sat, 01 Jan 2000 00:00:00 GMT")
    }

    @Test
    func appVersionChangeResetsToBundle() async throws {
        let temp = try Self.makeTempDir()
        let cacheDir = temp.appendingPathComponent("cache", isDirectory: true)
        let base = temp.appendingPathComponent("base.txt")
        try Data("base".utf8).write(to: base)

        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
        let cached = cacheDir.appendingPathComponent("base.txt")
        try Data("remote".utf8).write(to: cached)

        let metadataURL = cacheDir.appendingPathComponent("base.txt.metadata.json")
        let metadata = RemoteAssetMetadata(appVersion: "old", cacheHeaders: .init(etag: "\"v1\""))
        try JSONEncoder().encode(metadata).write(to: metadataURL)

        let manager = try await RemoteAssetManager(
            baseAsset: base,
            remoteAsset: try Self.remoteURL(),
            materialize: .init { try Self.utf8String($0) },
            fetcher: MockFetcher { _, _ in .init(data: nil, cacheHeaders: .init()) },
            cacheDirectory: cacheDir,
            cacheFileName: "base.txt",
            appVersion: "new"
        )

        #expect(await manager.asset == "base")

        let refreshedMetadata = try JSONDecoder().decode(RemoteAssetMetadata.self, from: Data(contentsOf: metadataURL))
        #expect(refreshedMetadata.appVersion == "new")
        #expect(refreshedMetadata.cacheHeaders.etag == nil)
    }

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    private static func remoteURL() throws -> URL {
        guard let url = URL(string: "https://example.invalid/asset") else {
            throw URLError(.badURL)
        }
        return url
    }

    private static func utf8String(_ data: Data) throws -> String {
        guard let string = String(bytes: data, encoding: .utf8) else {
            throw NotMaterializable()
        }
        return string
    }
}

private struct MockFetcher: RemoteAssetFetching {
    let handler: @Sendable (URL, RemoteAssetCacheHeaders) -> RemoteAssetFetchResult

    init(handler: @escaping @Sendable (URL, RemoteAssetCacheHeaders) -> RemoteAssetFetchResult) {
        self.handler = handler
    }

    func fetch(url: URL, cacheHeaders: RemoteAssetCacheHeaders) async throws -> RemoteAssetFetchResult {
        handler(url, cacheHeaders)
    }
}

private actor SequenceFetcher: RemoteAssetFetching {
    private var outcomes: [RemoteAssetFetchResult]

    init(outcomes: [RemoteAssetFetchResult]) {
        self.outcomes = outcomes
    }

    func fetch(url: URL, cacheHeaders: RemoteAssetCacheHeaders) async throws -> RemoteAssetFetchResult {
        if outcomes.isEmpty {
            return .init(data: nil, cacheHeaders: cacheHeaders)
        }
        return outcomes.removeFirst()
    }
}
