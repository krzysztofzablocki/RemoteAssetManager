import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(UIKit)
import UIKit

public extension Materializer where Asset == UIImage {
    static var uiImage: Materializer<UIImage> {
        Materializer<UIImage> { data in
            guard let image = UIImage(data: data) else {
                throw NotMaterializable()
            }
            return image
        }
    }
}

#if canImport(SwiftUI)
public extension Materializer where Asset == UIImage {
    var swiftUI: Materializer<Image> {
        .init { data in
            Image(uiImage: try self.closure(data))
        }
    }
}
#endif
#endif

#if canImport(AppKit)
import AppKit

public extension Materializer where Asset == NSImage {
    static var nsImage: Materializer<NSImage> {
        Materializer<NSImage> { data in
            guard let image = NSImage(data: data) else {
                throw NotMaterializable()
            }
            return image
        }
    }
}

#if canImport(SwiftUI)
public extension Materializer where Asset == NSImage {
    var swiftUI: Materializer<Image> {
        .init { data in
            Image(nsImage: try self.closure(data))
        }
    }
}
#endif
#endif
