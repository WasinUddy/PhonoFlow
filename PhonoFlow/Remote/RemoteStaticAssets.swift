//
//  RemoteStaticAssets.swift
//  PhonoFlow
//

import Foundation

nonisolated public struct RemoteStaticAsset: Sendable, Equatable {
    public var content: Data
    public var contentType: String
    public var cacheControl: String

    public init(content: Data, contentType: String, cacheControl: String) {
        self.content = content
        self.contentType = contentType
        self.cacheControl = cacheControl
    }
}

nonisolated public protocol RemoteStaticAssetProviding: Sendable {
    func asset(forRequestPath path: String) async -> RemoteStaticAsset?
}

/// Serves an allow-listed set of resources bundled with the native app. It never
/// maps arbitrary request paths to the filesystem.
public actor BundledRemoteStaticAssetProvider: nonisolated RemoteStaticAssetProviding {
    private struct Resource: Sendable {
        var name: String
        var extensionName: String
        var bundleSubdirectory: String
        var developmentRelativePath: String
        var contentType: String
        var cacheControl: String
    }

    private let bundle: Bundle
    private let developmentRoot: URL?
    private var cache: [String: RemoteStaticAsset] = [:]

    private static let resources: [String: Resource] = [
        "/": Resource(
            name: "index",
            extensionName: "html",
            bundleSubdirectory: "WebUI",
            developmentRelativePath: "index.html",
            contentType: "text/html; charset=utf-8",
            cacheControl: "no-cache"
        ),
        "/styles.css": Resource(
            name: "styles",
            extensionName: "css",
            bundleSubdirectory: "WebUI",
            developmentRelativePath: "styles.css",
            contentType: "text/css; charset=utf-8",
            cacheControl: "public, max-age=3600"
        ),
        "/src/app.js": Resource(
            name: "app",
            extensionName: "js",
            bundleSubdirectory: "WebUI/src",
            developmentRelativePath: "src/app.js",
            contentType: "text/javascript; charset=utf-8",
            cacheControl: "public, max-age=3600"
        ),
        "/src/api.js": Resource(
            name: "api",
            extensionName: "js",
            bundleSubdirectory: "WebUI/src",
            developmentRelativePath: "src/api.js",
            contentType: "text/javascript; charset=utf-8",
            cacheControl: "public, max-age=3600"
        ),
        "/src/state.js": Resource(
            name: "state",
            extensionName: "js",
            bundleSubdirectory: "WebUI/src",
            developmentRelativePath: "src/state.js",
            contentType: "text/javascript; charset=utf-8",
            cacheControl: "public, max-age=3600"
        ),
        "/src/spectrogram.js": Resource(
            name: "spectrogram",
            extensionName: "js",
            bundleSubdirectory: "WebUI/src",
            developmentRelativePath: "src/spectrogram.js",
            contentType: "text/javascript; charset=utf-8",
            cacheControl: "public, max-age=3600"
        ),
        "/src/view.js": Resource(
            name: "view",
            extensionName: "js",
            bundleSubdirectory: "WebUI/src",
            developmentRelativePath: "src/view.js",
            contentType: "text/javascript; charset=utf-8",
            cacheControl: "public, max-age=3600"
        ),
    ]

    public init(
        bundle: Bundle = .main,
        developmentRoot: URL? = nil
    ) {
        self.bundle = bundle
        self.developmentRoot = developmentRoot
    }

    public func asset(forRequestPath path: String) async -> RemoteStaticAsset? {
        guard let resource = Self.resources[path] else { return nil }
        if let cached = cache[path] {
            return cached
        }

        guard let url = resourceURL(for: resource),
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else {
            return nil
        }

        let asset = RemoteStaticAsset(
            content: data,
            contentType: resource.contentType,
            cacheControl: resource.cacheControl
        )
        cache[path] = asset
        return asset
    }

    private func resourceURL(for resource: Resource) -> URL? {
        if let url = bundle.url(
            forResource: resource.name,
            withExtension: resource.extensionName,
            subdirectory: resource.bundleSubdirectory
        ) {
            return url
        }

        #if DEBUG
            if let developmentRoot {
                let url =
                    developmentRoot
                    .appendingPathComponent(resource.developmentRelativePath)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        #endif
        return nil
    }
}

/// Useful for deterministic tests that should not depend on an application bundle.
public actor InMemoryRemoteStaticAssetProvider: nonisolated RemoteStaticAssetProviding {
    private var assets: [String: RemoteStaticAsset]

    public init(assets: [String: RemoteStaticAsset]) {
        self.assets = assets
    }

    public func asset(forRequestPath path: String) async -> RemoteStaticAsset? {
        assets[path]
    }
}
