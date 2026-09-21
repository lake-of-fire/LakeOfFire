import Foundation
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI
#if os(macOS)
import AppKit
#endif

private actor ReaderFileStatusRefreshWaitGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func release() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}

@MainActor
final class ReaderFileStatusRefreshLifetimeTests: XCTestCase {
    func test_cancelledCaller_doesNotSupersedeActiveRefresh() async {
        let item = ContentFile()
        let readGate = ReaderFileStatusRefreshWaitGate()
        let callerGate = ReaderFileStatusRefreshWaitGate()
        let activeRefreshEntered = expectation(description: "Active status refresh entered")
        let cancelledCallerEntered = expectation(description: "Cancelled caller waiting")
        var readCount = 0
        let model = CloudDriveSyncStatusModel(statusLoader: { _ in
            readCount += 1
            if readCount == 1 {
                activeRefreshEntered.fulfill()
                await readGate.wait()
                return .availableLocally
            }
            return .cloudOnly
        })

        let cancelledCaller = Task { @MainActor in
            cancelledCallerEntered.fulfill()
            await callerGate.wait()
            await model.refreshAsync(item: item)
        }
        await fulfillment(of: [cancelledCallerEntered], timeout: 3)

        let activeRefresh = Task { @MainActor in
            await model.refreshAsync(item: item)
        }
        await fulfillment(of: [activeRefreshEntered], timeout: 3)

        cancelledCaller.cancel()
        await callerGate.release()
        await cancelledCaller.value
        XCTAssertEqual(readCount, 1)

        await readGate.release()
        await activeRefresh.value
        guard case .availableLocally = model.status else {
            return XCTFail("Expected the active refresh to publish its result")
        }
    }

#if os(macOS)
    private final class Visibility: ObservableObject {
        @Published var isVisible = true
    }

    private struct Host: View {
        @ObservedObject var visibility: Visibility
        let item: ContentFile
        let statusModel: CloudDriveSyncStatusModel
        let statusLoader: CloudDriveSyncStatusModel.StatusLoader

        var body: some View {
            Group {
                if visibility.isVisible {
                    Text("Status lifecycle fixture")
                        .modifier(
                            ReaderFileStatusRefreshModifier(
                                item: item,
                                statusModel: statusModel,
                                statusLoader: statusLoader
                            )
                        )
                } else {
                    Text("Removed")
                }
            }
        }
    }

    func test_notificationReplacement_isCancelledWhenRowDisappears() async throws {
        let initialRefreshEntered = expectation(description: "Initial status refresh entered")
        let replacementRefreshEntered = expectation(description: "Replacement status refresh entered")
        let replacementRefreshCancelled = expectation(description: "Replacement cancelled on disappearance")
        let gate = ReaderFileStatusRefreshWaitGate()
        var readCount = 0
        let statusLoader: CloudDriveSyncStatusModel.StatusLoader = { _ in
            readCount += 1
            let currentRead = readCount
            return await withTaskCancellationHandler {
                if currentRead == 1 {
                    initialRefreshEntered.fulfill()
                } else if currentRead == 2 {
                    replacementRefreshEntered.fulfill()
                }
                await gate.wait()
                return .availableLocally
            } onCancel: {
                if currentRead == 2 {
                    replacementRefreshCancelled.fulfill()
                }
            }
        }
        let model = CloudDriveSyncStatusModel(statusLoader: statusLoader)
        let item = ContentFile()
        item.url = try XCTUnwrap(URL(string: "reader-file://file/load/local/\(UUID().uuidString).txt"))
        item.updateCompoundKey()
        let readerFileManager = ReaderFileManager()
        let requestedURLString = try XCTUnwrap(
            readerFileManager.canonicalReaderBackingURL(for: item.url)?.absoluteString
        )
        let visibility = Visibility()
        let host = NSHostingController(
            rootView: Host(
                visibility: visibility,
                item: item,
                statusModel: model,
                statusLoader: statusLoader
            )
                .environmentObject(readerFileManager)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFront(nil)

        await fulfillment(of: [initialRefreshEntered], timeout: 3)
        NotificationCenter.default.post(
            name: ReaderFileManager.readerBackingStatusRefreshRequestedNotification,
            object: requestedURLString
        )
        await fulfillment(of: [replacementRefreshEntered], timeout: 3)
        visibility.isVisible = false
        await fulfillment(of: [replacementRefreshCancelled], timeout: 3)

        await gate.release()
        window.close()
        XCTAssertEqual(readCount, 2)
    }
#endif
}
