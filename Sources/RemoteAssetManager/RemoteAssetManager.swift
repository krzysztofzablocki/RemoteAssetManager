import CryptoKit
import Foundation

public struct RemoteAssetMetadata: Codable, Equatable, Sendable {
    public var appVersion: String
    public var cacheHeaders: RemoteAssetCacheHeaders
    public var lastCheckedAt: Date?
    public var lastUpdatedAt: Date?
    public var byteCount: Int?
    public var contentHash: String?

    public init(
        appVersion: String,
        cacheHeaders: RemoteAssetCacheHeaders = .init(),
        lastCheckedAt: Date? = nil,
        lastUpdatedAt: Date? = nil,
        byteCount: Int? = nil,
        contentHash: String? = nil
    ) {
        self.appVersion = appVersion
        self.cacheHeaders = cacheHeaders
        self.lastCheckedAt = lastCheckedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.byteCount = byteCount
        self.contentHash = contentHash
    }
}

public struct RemoteAssetStatus: Equatable, Sendable {
    public var remoteAsset: URL
    public var cacheFileName: String
    public var appVersion: String
    public var cacheHeaders: RemoteAssetCacheHeaders
    public var lastCheckedAt: Date?
    public var lastUpdatedAt: Date?
    public var byteCount: Int
    /// A stable fingerprint of the currently loaded bytes (SHA-256 hex prefix).
    public var contentHash: String

    public init(
        remoteAsset: URL,
        cacheFileName: String,
        appVersion: String,
        cacheHeaders: RemoteAssetCacheHeaders,
        lastCheckedAt: Date?,
        lastUpdatedAt: Date?,
        byteCount: Int,
        contentHash: String
    ) {
        self.remoteAsset = remoteAsset
        self.cacheFileName = cacheFileName
        self.appVersion = appVersion
        self.cacheHeaders = cacheHeaders
        self.lastCheckedAt = lastCheckedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.byteCount = byteCount
        self.contentHash = contentHash
    }
}

public enum RemoteAssetRefreshOutcome: Sendable {
    case notModified
    case updated
    /// A refresh is already running. No network request was started.
    case inFlight
}

/// Downloads and caches a remote asset, supporting conditional requests via ETag / Last-Modified.
///
/// - Note: This type is intentionally *not* `@MainActor`. UI layers can wrap it as needed.
public actor RemoteAssetManager<Asset: Sendable> {
    public private(set) var asset: Asset
    public private(set) var isRefreshing: Bool = false
    public private(set) var status: RemoteAssetStatus

    private let remoteAssetURL: URL
    private let cachedAssetURL: URL
    private let metadataURL: URL
    private let appVersion: String
    private let materialize: Materializer<Asset>
    private let fetcher: any RemoteAssetFetching
    private let store: RemoteAssetStore

    private var autoRefreshTask: Task<Void, Never>?

    private struct CachePaths: Sendable {
        var cacheDirectory: URL
        var cacheFileName: String
        var cachedAssetURL: URL
        var metadataURL: URL
    }

    private struct InitialLoad: Sendable {
        var store: RemoteAssetStore
        var data: Data
        var metadata: RemoteAssetMetadata
    }

    private struct StatusBuild: Sendable {
        var status: RemoteAssetStatus
        var metadataToPersist: RemoteAssetMetadata?
    }

    public init(
        baseAsset: URL,
        remoteAsset: URL,
        materialize: Materializer<Asset>,
        fetcher: some RemoteAssetFetching = URLSessionRemoteAssetFetcher(),
        cacheDirectory: URL? = nil,
        cacheFileName: String? = nil,
        appVersion: String? = nil,
        autoRefreshEvery interval: Duration? = nil,
        refreshOnInit: Bool = true
    ) async throws {
        try Self.validateBaseAssetURL(baseAsset)

        let resolvedAppVersion = Self.resolveAppVersion(appVersion)
        let paths = try Self.resolveCachePaths(
            baseAsset: baseAsset,
            remoteAsset: remoteAsset,
            cacheDirectory: cacheDirectory,
            cacheFileName: cacheFileName
        )

        let initial = try await Self.loadInitial(
            baseAssetURL: baseAsset,
            baseData: nil,
            cachePaths: paths,
            appVersion: resolvedAppVersion
        )

        asset = try materialize(initial.data)
        remoteAssetURL = remoteAsset
        cachedAssetURL = paths.cachedAssetURL
        metadataURL = paths.metadataURL
        self.appVersion = resolvedAppVersion
        self.materialize = materialize
        self.fetcher = fetcher
        store = initial.store
        autoRefreshTask = nil

        let statusBuild = Self.buildStatus(
            remoteAsset: remoteAsset,
            cacheFileName: paths.cacheFileName,
            appVersion: resolvedAppVersion,
            metadata: initial.metadata,
            data: initial.data
        )
        status = statusBuild.status

        if let metadataToPersist = statusBuild.metadataToPersist {
            await initial.store.writeMetadata(metadata: metadataToPersist, metadataURL: paths.metadataURL)
        }

        configureBackgroundTasks(autoRefreshEvery: interval, refreshOnInit: refreshOnInit)
    }

    public init(
        baseData: Data,
        remoteAsset: URL,
        materialize: Materializer<Asset>,
        fetcher: some RemoteAssetFetching = URLSessionRemoteAssetFetcher(),
        cacheDirectory: URL? = nil,
        cacheFileName: String? = nil,
        appVersion: String? = nil,
        autoRefreshEvery interval: Duration? = nil,
        refreshOnInit: Bool = true
    ) async throws {
        let resolvedAppVersion = Self.resolveAppVersion(appVersion)
        let paths = try Self.resolveCachePaths(
            baseAsset: nil,
            remoteAsset: remoteAsset,
            cacheDirectory: cacheDirectory,
            cacheFileName: cacheFileName
        )

        let initial = try await Self.loadInitial(
            baseAssetURL: nil,
            baseData: baseData,
            cachePaths: paths,
            appVersion: resolvedAppVersion
        )

        asset = try materialize(initial.data)
        remoteAssetURL = remoteAsset
        cachedAssetURL = paths.cachedAssetURL
        metadataURL = paths.metadataURL
        self.appVersion = resolvedAppVersion
        self.materialize = materialize
        self.fetcher = fetcher
        store = initial.store
        autoRefreshTask = nil

        let statusBuild = Self.buildStatus(
            remoteAsset: remoteAsset,
            cacheFileName: paths.cacheFileName,
            appVersion: resolvedAppVersion,
            metadata: initial.metadata,
            data: initial.data
        )
        status = statusBuild.status

        if let metadataToPersist = statusBuild.metadataToPersist {
            await initial.store.writeMetadata(metadata: metadataToPersist, metadataURL: paths.metadataURL)
        }

        configureBackgroundTasks(autoRefreshEvery: interval, refreshOnInit: refreshOnInit)
    }

    @discardableResult
    public func refresh() async throws -> RemoteAssetRefreshOutcome {
        if isRefreshing {
            return .inFlight
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let metadata = await store.readMetadata(metadataURL: metadataURL, appVersion: appVersion)
            let result = try await fetcher.fetch(url: remoteAssetURL, cacheHeaders: metadata.cacheHeaders)
            let now = Date()

            if let data = result.data {
                let materialized = try materialize(data)
                try await store.writeAssetData(data: data, assetURL: cachedAssetURL)
                asset = materialized

                let contentHash = Self.sha256PrefixHex(of: data)
                let updated = RemoteAssetMetadata(
                    appVersion: appVersion,
                    cacheHeaders: result.cacheHeaders,
                    lastCheckedAt: now,
                    lastUpdatedAt: now,
                    byteCount: data.count,
                    contentHash: contentHash
                )
                await store.writeMetadata(metadata: updated, metadataURL: metadataURL)

                status.cacheHeaders = result.cacheHeaders
                status.lastCheckedAt = now
                status.lastUpdatedAt = now
                status.byteCount = data.count
                status.contentHash = contentHash
                return .updated
            }

            var updated = metadata
            updated.appVersion = appVersion
            updated.cacheHeaders = result.cacheHeaders
            updated.lastCheckedAt = now
            await store.writeMetadata(metadata: updated, metadataURL: metadataURL)

            status.cacheHeaders = result.cacheHeaders
            status.lastCheckedAt = now
        } catch {
            throw error
        }

        return .notModified
    }

    private func configureBackgroundTasks(autoRefreshEvery interval: Duration?, refreshOnInit: Bool) {
        if let interval {
            startAutoRefresh(every: interval)
        }

        if refreshOnInit {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.refresh()
            }
        }
    }

    private static func validateBaseAssetURL(_ baseAsset: URL) throws {
        guard baseAsset.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard FileManager.default.fileExists(atPath: baseAsset.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private static func resolveAppVersion(_ provided: String?) -> String {
        provided ?? currentAppVersion(bundle: .main)
    }

    private static func resolveCachePaths(
        baseAsset: URL?,
        remoteAsset: URL,
        cacheDirectory: URL?,
        cacheFileName: String?
    ) throws -> CachePaths {
        let resolvedCacheDirectory = try resolveCacheDirectory(cacheDirectory)
        let resolvedFileName = cacheFileName ?? defaultCacheFileName(baseAsset: baseAsset, remoteAsset: remoteAsset)
        return CachePaths(
            cacheDirectory: resolvedCacheDirectory,
            cacheFileName: resolvedFileName,
            cachedAssetURL: resolvedCacheDirectory.appendingPathComponent(resolvedFileName),
            metadataURL: resolvedCacheDirectory.appendingPathComponent("\(resolvedFileName).metadata.json")
        )
    }

    private static func loadInitial(
        baseAssetURL: URL?,
        baseData: Data?,
        cachePaths: CachePaths,
        appVersion: String
    ) async throws -> InitialLoad {
        let store = RemoteAssetStore()
        try await store.bootstrap(
            baseAssetURL: baseAssetURL,
            baseData: baseData,
            cachedAssetURL: cachePaths.cachedAssetURL,
            metadataURL: cachePaths.metadataURL,
            appVersion: appVersion
        )

        let data = try await store.readAssetData(
            assetURL: cachePaths.cachedAssetURL,
            baseAssetURL: baseAssetURL,
            baseData: baseData
        )
        let metadata = await store.readMetadata(metadataURL: cachePaths.metadataURL, appVersion: appVersion)
        return InitialLoad(store: store, data: data, metadata: metadata)
    }

    private static func buildStatus(
        remoteAsset: URL,
        cacheFileName: String,
        appVersion: String,
        metadata: RemoteAssetMetadata,
        data: Data
    ) -> StatusBuild {
        let contentHash = sha256PrefixHex(of: data)

        var updatedMetadata: RemoteAssetMetadata?
        if metadata.byteCount != data.count || metadata.contentHash != contentHash || metadata.lastUpdatedAt == nil {
            var next = metadata
            next.byteCount = data.count
            next.contentHash = contentHash
            if next.lastUpdatedAt == nil {
                next.lastUpdatedAt = Date()
            }
            updatedMetadata = next
        }

        let effective = updatedMetadata ?? metadata
        return StatusBuild(
            status: RemoteAssetStatus(
                remoteAsset: remoteAsset,
                cacheFileName: cacheFileName,
                appVersion: appVersion,
                cacheHeaders: effective.cacheHeaders,
                lastCheckedAt: effective.lastCheckedAt,
                lastUpdatedAt: effective.lastUpdatedAt,
                byteCount: data.count,
                contentHash: contentHash
            ),
            metadataToPersist: updatedMetadata
        )
    }

    public func startAutoRefresh(every interval: Duration) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = try? await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private static func resolveCacheDirectory(_ provided: URL?) throws -> URL {
        if let provided {
            return provided
        }

        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        return caches.appendingPathComponent("RemoteAssetManager", isDirectory: true)
    }

    private static func currentAppVersion(bundle: Bundle) -> String {
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String
        if let short, let build {
            return "\(short) (\(build))"
        }
        return short ?? build ?? "unknown"
    }

    private static func defaultCacheFileName(baseAsset: URL?, remoteAsset: URL) -> String {
        let baseName: String
        if let baseAsset, !baseAsset.lastPathComponent.isEmpty {
            baseName = baseAsset.lastPathComponent
        } else {
            baseName = "asset"
        }
        let digest = SHA256.hash(data: Data(remoteAsset.absoluteString.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        let prefix = hex.prefix(16)
        return "\(baseName).\(prefix)"
    }

    private static func sha256PrefixHex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}

private actor RemoteAssetStore {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func bootstrap(
        baseAssetURL: URL?,
        baseData: Data?,
        cachedAssetURL: URL,
        metadataURL: URL,
        appVersion: String
    ) throws {
        let directory = cachedAssetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let existingMetadata = readMetadataIfPresent(metadataURL: metadataURL)
        if let existingMetadata, existingMetadata.appVersion != appVersion {
            try? FileManager.default.removeItem(at: cachedAssetURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }

        if !FileManager.default.fileExists(atPath: cachedAssetURL.path) {
            if let baseAssetURL {
                if cachedAssetURL != baseAssetURL {
                    try FileManager.default.copyItem(at: baseAssetURL, to: cachedAssetURL)
                }
            } else if let baseData {
                try baseData.write(to: cachedAssetURL, options: .atomic)
            }
        }

        if readMetadataIfPresent(metadataURL: metadataURL)?.appVersion != appVersion {
            let fresh = RemoteAssetMetadata(appVersion: appVersion, cacheHeaders: .init())
            writeMetadata(metadata: fresh, metadataURL: metadataURL)
        }
    }

    func readAssetData(assetURL: URL, baseAssetURL: URL?, baseData: Data?) throws -> Data {
        do {
            return try Data(contentsOf: assetURL)
        } catch {
            try? FileManager.default.removeItem(at: assetURL)

            if let baseAssetURL {
                try FileManager.default.copyItem(at: baseAssetURL, to: assetURL)
                return try Data(contentsOf: assetURL)
            }

            if let baseData {
                try baseData.write(to: assetURL, options: .atomic)
                return baseData
            }

            throw error
        }
    }

    func writeAssetData(data: Data, assetURL: URL) throws {
        try data.write(to: assetURL, options: .atomic)
    }

    func readMetadata(metadataURL: URL, appVersion: String) -> RemoteAssetMetadata {
        if let metadata = readMetadataIfPresent(metadataURL: metadataURL), metadata.appVersion == appVersion {
            return metadata
        }
        return RemoteAssetMetadata(appVersion: appVersion, cacheHeaders: .init())
    }

    func writeMetadata(metadata: RemoteAssetMetadata, metadataURL: URL) {
        do {
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            // Best-effort: failing to write metadata should not break asset loading.
        }
    }

    private func readMetadataIfPresent(metadataURL: URL) -> RemoteAssetMetadata? {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            return try decoder.decode(RemoteAssetMetadata.self, from: data)
        } catch {
            return nil
        }
    }
}
