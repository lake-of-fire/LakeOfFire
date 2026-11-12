import Foundation
import XCTest
import LakeOfFireContent
@testable import LakeOfFireReader

private enum FixtureReadError: Error { case unavailable }

final class ReaderEBookNativeRestorePreparationTests: XCTestCase {
    func testPreCancelledPreparationDoesNotRead() async {
        let result = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            var calls = 0
            do {
                _ = try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                    calls += 1
                    return .init(cfi: "", fractionalCompletion: 0)
                }
                return false
            } catch is CancellationError { return calls == 0 }
            catch { return false }
        }.value
        XCTAssertTrue(result)
    }

    func testCancellationAfterAProviderReturnsZeroCannotPublishRequest() async {
        let result = await Task { @MainActor in
            do {
                _ = try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .init(cfi: "", fractionalCompletion: 0)
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(result)
    }

    func testCancellationAfterAProviderReturnsNilIsNotNoTarget() async {
        let result = await Task { @MainActor in
            do {
                _ = try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(result)
    }

    func testReadErrorPropagatesAndAnIndependentRetryCanSucceed() async throws {
        let result = try await Task { @MainActor in
            var failurePropagated = false
            do {
                _ = try await ReaderEBookInitialRestoreBridgeRequest.prepare { throw FixtureReadError.unavailable }
            } catch FixtureReadError.unavailable { failurePropagated = true }
            let retry = try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                .init(cfi: "", fractionalCompletion: 0)
            }
            return failurePropagated && retry?.fractionalCompletion == 0
        }.value
        XCTAssertTrue(result)
    }

    func testOnlyAnAbsentValueProducesNoTargetWhileMalformedValueThrows() async throws {
        let result = try await Task { @MainActor in
            let missing = try await ReaderEBookInitialRestoreBridgeRequest.prepare { nil }
            var invalidThrows = false
            do {
                _ = try await ReaderEBookInitialRestoreBridgeRequest.prepare {
                    .init(cfi: "epubcfi(/6/4!)", fractionalCompletion: .infinity)
                }
            } catch ReaderEBookInitialRestoreError.invalidFraction { invalidThrows = true }
            return missing == nil && invalidThrows
        }.value
        XCTAssertTrue(result)
    }
}
