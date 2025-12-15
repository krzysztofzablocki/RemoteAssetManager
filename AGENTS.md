# Repository Guidelines

## Project Structure & Module Organization

- `Package.swift`: Swift Package Manager manifest (library target `RemoteAssetManager`).
- `Sources/RemoteAssetManager/`: library implementation (async/await + `actor`-based state).
- `Tests/RemoteAssetManagerTests/`: Swift Testing suite (`import Testing`).
- Build artifacts live in `.build/` (ignored by git).

## Build, Test, and Development Commands

Run these from the repo root:

- `swift build`: compile the library.
- `swift test`: run the test suite.
- `swift package describe`: print the resolved package structure (useful for debugging targets/products).

Tip: open the package in Xcode by opening `Package.swift` directly.

## Coding Style & Naming Conventions

- Language: Swift (Swift 6 toolchain per `Package.swift`).
- Indentation: 4 spaces; prefer the default Xcode/SwiftPM formatting.
- Follow Swift API Design Guidelines and keep public API surface intentional.
- Formatting/linting: run via `pre-commit` (`SwiftFormat` uses `.swiftformat`, `SwiftLint` uses `.swiftlint.yml`).
- Naming: types/protocols in `UpperCamelCase` (e.g., `RemoteAssetManager`, `RemoteAssetFetching`), methods/properties in `lowerCamelCase`.
- Concurrency: avoid blocking inside async code; prefer dependency injection (e.g., `RemoteAssetFetching`) over real networking in tests.

## Testing Guidelines

- Framework: Swift Testing (`import Testing`).
- Keep tests deterministic: do not hit the network; inject a test fetcher conforming to `RemoteAssetFetching`.
- Use `@Suite` + `@Test` and write behavior-focused test names (e.g., `refreshDoesNotOverwriteOnNotModified()`).
- Prefer `#expect(...)` assertions over custom helpers.
- Run: `swift test`.

## Commit & Pull Request Guidelines

- Use semantic commit messages (Conventional Commits), e.g. `feat: add conditional fetch headers`, `fix: avoid cache metadata drift`.
- PRs: include a short summary, rationale, and test notes (`swift test` output). Link issues if applicable.

## Security & Configuration Tips

- Never commit secrets (tokens, private URLs, credentials). Use environment variables or local config files ignored by git.
- Treat cached on-disk data as potentially untrusted: validate during materialization and handle failures explicitly.
