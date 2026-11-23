import Dispatch
import Foundation
import LakeOfFireCore
import XCTest

final class ReaderProtocolRegistryTests: XCTestCase {
    func testLookupUsesExactSchemeAndKeepsFirstRegistration() throws {
        let registry = ReaderProtocolRegistry(readerProtocols: [
            UppercaseRegistryReader.self, FirstRegistryReader.self, DuplicateRegistryReader.self,
        ])
        let firstURL = try XCTUnwrap(URL(string: "lookup-registry://item"))
        let additionalURL = try XCTUnwrap(URL(string: "additional-registry://item"))
        let relativeURL = try XCTUnwrap(URL(string: "relative-item"))

        XCTAssertEqual(readerTypeID(registry.get(forURL: firstURL)), ObjectIdentifier(FirstRegistryReader.self))
        XCTAssertNil(registry.get(forURL: additionalURL))
        XCTAssertNil(registry.get(forURL: relativeURL))

        AdditionalRegistryReader.register(inReistry: registry)

        XCTAssertEqual(readerTypeID(registry.get(forURL: additionalURL)), ObjectIdentifier(AdditionalRegistryReader.self))
        XCTAssertEqual(readerTypeID(registry.get(forURL: firstURL)), ObjectIdentifier(FirstRegistryReader.self))
    }

    func testConcurrentRegistrationAndLookupPreserveTheFirstMatch() async throws {
        let registry = ReaderProtocolRegistry(readerProtocols: [FirstRegistryReader.self])
        let firstURL = try XCTUnwrap(URL(string: "lookup-registry://item"))
        let additionalURL = try XCTUnwrap(URL(string: "additional-registry://item"))

        let mismatchCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    registry.register(DuplicateRegistryReader.self)
                    registry.register(AdditionalRegistryReader.self)
                    return readerTypeID(registry.get(forURL: firstURL)) == ObjectIdentifier(FirstRegistryReader.self)
                        && readerTypeID(registry.get(forURL: additionalURL)) == ObjectIdentifier(AdditionalRegistryReader.self)
                }
            }

            var mismatchCount = 0
            for await matchedExpectedReaders in group {
                if !matchedExpectedReaders { mismatchCount += 1 }
            }
            return mismatchCount
        }

        XCTAssertEqual(mismatchCount, 0)
    }

    func testSchemeGetterCanRegisterDuringLookupWithoutChangingItsSnapshot() throws {
        let registry = ReaderProtocolRegistry(readerProtocols: [RegisteringRegistryReader.self])
        let probe = RegistrySchemeProbe(registry: registry)
        let additionalURL = try XCTUnwrap(URL(string: "additional-registry://item"))

        let match = RegisteringRegistryReader.$probe.withValue(probe) {
            registry.get(forURL: additionalURL)
        }

        // The getter's wait is bounded. If a lookup held the lock during the
        // callback, the worker can finish as soon as that lookup unwinds.
        guard case .success = probe.registrations.wait(timeout: .now() + 5) else {
            return XCTFail("Registration did not finish after the getter returned")
        }
        guard case .success = probe.completedDuringGetter.wait(timeout: .now()) else {
            return XCTFail("The getter could not wait for registration during lookup")
        }
        XCTAssertNil(match, "A lookup uses the registrations captured before calling conformers")
        XCTAssertEqual(readerTypeID(registry.get(forURL: additionalURL)), ObjectIdentifier(AdditionalRegistryReader.self))
    }
}

private func readerTypeID(_ type: ReaderProtocol.Type?) -> ObjectIdentifier? {
    type.map { ObjectIdentifier($0) }
}

private enum UppercaseRegistryReader: ReaderProtocol {
    static let urlScheme = "LOOKUP-REGISTRY"
    static func providesNativeReaderView(forURL _: URL) -> Bool { true }
}

private enum FirstRegistryReader: ReaderProtocol {
    static let urlScheme = "lookup-registry"
    static func providesNativeReaderView(forURL _: URL) -> Bool { true }
}

private enum DuplicateRegistryReader: ReaderProtocol {
    static let urlScheme = "lookup-registry"
    static func providesNativeReaderView(forURL _: URL) -> Bool { true }
}

private enum AdditionalRegistryReader: ReaderProtocol {
    static let urlScheme = "additional-registry"
    static func providesNativeReaderView(forURL _: URL) -> Bool { true }
}

private struct RegistrySchemeProbe: Sendable {
    let registry: ReaderProtocolRegistry
    let registrations = DispatchGroup()
    let completedDuringGetter = DispatchSemaphore(value: 0)
}

private enum RegisteringRegistryReader: ReaderProtocol {
    @TaskLocal static var probe: RegistrySchemeProbe?

    static var urlScheme: String {
        if let probe {
            let completion = DispatchSemaphore(value: 0)
            DispatchQueue.global().async(group: probe.registrations) {
                probe.registry.register(AdditionalRegistryReader.self)
                completion.signal()
            }
            if case .success = completion.wait(timeout: .now() + 5) {
                probe.completedDuringGetter.signal()
            }
        }
        return "callback-registry"
    }

    static func providesNativeReaderView(forURL _: URL) -> Bool { true }
}
