import Foundation

@inlinable
public func urlsMatchWithoutHash(_ lhs: URL?, _ rhs: URL?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (.some(lhsURL), .some(rhsURL)):
        if lhsURL == rhsURL {
            return true
        }
        return lhsURL.removingFragmentIfNeeded() == rhsURL.removingFragmentIfNeeded()
    default:
        return false
    }
}

internal extension URL {
    @usableFromInline
    func removingFragmentIfNeeded() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.fragment != nil else {
            return self
        }
        components.fragment = nil
        return components.url ?? self
    }
}
