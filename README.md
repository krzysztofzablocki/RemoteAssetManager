# RemoteAssetManager

Async-first remote asset loader with on-disk caching and conditional HTTP (ETag / Last-Modified).

`RemoteAssetManager` is an `actor` (not `@MainActor`). Access to its state (like `asset`) is done with `await`.

## What You Get

- **Async-first API**: `async` init + `async` refresh.
- **Conditional HTTP**: sends `If-None-Match` / `If-Modified-Since`; handles HTTP `304 Not Modified`.
- **On-disk cache**: keeps the last good asset on disk for fast startup and offline use.
- **Validation via materialization**: your `Materializer` can throw; if it throws, the cache is not updated.
- **Auto-refresh polling**: optional periodic refresh without tying anything to the main thread.
- **Testable**: inject a custom `RemoteAssetFetching` implementation.

## How It Works

1. Bootstrap a cache file from a base asset (from disk) or base data (generated defaults).
2. Materialize the cached bytes into your in-memory `Asset` type.
3. On refresh, fetch from the remote URL using conditional request headers.
4. If the remote is **modified** (e.g. 200), run your `Materializer`:
   - If it succeeds, write the new bytes + updated cache headers to disk and update `asset`.
   - If it fails, keep the previous cached asset and do not advance metadata.
5. If the remote is **not modified** (304), keep the current asset and just persist updated cache headers.

## Usage

```swift
import Foundation
import RemoteAssetManager

let manager = try await RemoteAssetManager(
    baseAsset: Bundle.main.url(forResource: "config", withExtension: "json")!,
    remoteAsset: URL(string: "https://example.com/config.json")!,
    materialize: .init { data in
        try JSONDecoder().decode(Config.self, from: data)
    }
)

let initial = await manager.asset

let outcome = try? await manager.refresh() // optional manual refresh
await manager.startAutoRefresh(every: .seconds(30 * 60))
```

By default, the cache file name is derived from `baseAsset` plus a stable hash of `remoteAsset` to avoid collisions.

## Notes

- Conditional requests: `URLSessionRemoteAssetFetcher` sends `If-None-Match` / `If-Modified-Since` when cached headers exist.
- Validation: the `Materializer` can throw; on failure the cached asset and metadata are not updated.

## Refresh Outcomes + Errors

`refresh()` returns:
- `.updated` when new bytes were downloaded and applied
- `.notModified` for HTTP 304
- `.inFlight` when a refresh is already running
and throws if an error occurred.

```swift
do {
    switch try await manager.refresh() {
    case .updated: print("applied new asset")
    case .notModified: print("no change")
    case .inFlight: print("refresh already running")
    }
} catch {
    let status = await manager.status
    print("refresh failed:", error, "using:", status)
}
```

## Base Data (No Bundled File)

If you don’t have a bundled file URL, you can provide default bytes directly:

```swift
let defaultConfig = Config.default
let baseData = try JSONEncoder().encode(defaultConfig)

let manager = try await RemoteAssetManager(
    baseData: baseData,
    remoteAsset: URL(string: "https://example.com/config.json")!,
    materialize: .init { data in
        try JSONDecoder().decode(Config.self, from: data)
    }
)
```

## Custom URLSession / Networking Policy

You can provide a custom session (e.g. with a tuned `URLCache`, timeouts, proxies, etc.):

```swift
let cache = URLCache(memoryCapacity: 10_000_000, diskCapacity: 100_000_000)
let config = URLSessionConfiguration.default
config.urlCache = cache
config.requestCachePolicy = .useProtocolCachePolicy

let session = URLSession(configuration: config)
let fetcher = URLSessionRemoteAssetFetcher(session: session)

let manager = try await RemoteAssetManager(
    baseAsset: Bundle.main.url(forResource: "config", withExtension: "json")!,
    remoteAsset: URL(string: "https://example.com/config.json")!,
    materialize: .init { data in try JSONDecoder().decode(Config.self, from: data) },
    fetcher: fetcher
)
```

## UI Integration (Optional Wrapper)

The core type is intentionally not `@MainActor`. If you want to bind it into a UI, wrap it:

```swift
import Foundation
import Observation
import RemoteAssetManager

@MainActor
@Observable
final class RemoteConfigModel {
    private let manager: RemoteAssetManager<Config>
    private(set) var config: Config
    private(set) var status: RemoteAssetStatus

    init(manager: RemoteAssetManager<Config>) async {
        self.manager = manager
        self.config = await manager.asset
        self.status = await manager.status
    }

    func refresh() async {
        _ = try? await manager.refresh()
        config = await manager.asset
        status = await manager.status
    }
}
```

## Testing (Inject a Fetcher)

In tests, implement `RemoteAssetFetching` to control responses:

```swift
struct TestFetcher: RemoteAssetFetching {
    let response: @Sendable () -> RemoteAssetFetchResult
    func fetch(url: URL, cacheHeaders: RemoteAssetCacheHeaders) async throws -> RemoteAssetFetchResult {
        response()
    }
}
```

## App Version Changes

`RemoteAssetManager` persists metadata alongside the cache file. If `appVersion` changes, it resets the cached asset
back to the provided base asset/data to avoid using stale formats.
