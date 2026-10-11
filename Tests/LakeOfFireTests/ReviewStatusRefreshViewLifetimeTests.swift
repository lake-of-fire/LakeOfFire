import Combine
import Foundation
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private actor ReviewStatusWaitGate {
    private var open = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            if open { continuation.resume() }
            else { continuations.append(continuation) }
        }
    }
    func release() {
        open = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
final class ReviewStatusRefreshViewLifetimeTests: XCTestCase {
    func testFileInventoryPublicationInvalidatesObservers() {
        let manager = ReaderFileManager()
        var changes = 0
        let subscription = manager.objectWillChange.sink { changes += 1 }
        let item = ContentFile()
        item.url = URL(string: "reader-file://file/load/local/Books/\(UUID().uuidString).epub")!
        item.updateCompoundKey()
        manager.files = []
        manager.files = [item]
        XCTAssertEqual(manager.files?.map(\.compoundKey), [item.compoundKey])
        manager.files = []
        XCTAssertEqual(changes, 3, "Initial inventory, imports and deletions must invalidate library consumers")
        withExtendedLifetime(subscription) { }
    }

    func testRefreshPublishesAnObservableObjectChange() async {
        let model = CloudDriveSyncStatusModel(statusLoader: { _ in .localOnly })
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        await model.refreshAsync(item: ContentFile())
        XCTAssertEqual(model.status, .localOnly)
        XCTAssertEqual(changes, 1, "A successful status read must invalidate the observing row")
        withExtendedLifetime(subscription) { }
    }

#if os(iOS)
    private struct StatusRow: View {
        @StateObject private var status: CloudDriveSyncStatusModel
        let item: ContentFile
        let enabled: () -> Void

        init(status: CloudDriveSyncStatusModel, item: ContentFile, enabled: @escaping () -> Void) {
            _status = StateObject(wrappedValue: status)
            self.item = item
            self.enabled = enabled
        }

        var body: some View {
            let blocked = status.status == .loadingStatus || status.status == .cloudOnly
            Text(blocked ? "Delete unavailable" : "Delete available")
                .swipeActions {
                    Button("Delete") { }
                        .disabled(blocked)
                }
                .onChange(of: blocked) { blocked in
                    if !blocked { enabled() }
                }
                .modifier(ReaderFileStatusRefreshModifier(item: item, statusModel: status))
        }
    }

    @available(iOS 16.0, *)
    func testIOSListRowEnablesDeleteAfterItsStatusRefresh() async {
        let entered = expectation(description: "visible row starts its status read")
        let enabled = expectation(description: "published status enables the rendered swipe action")
        let gate = ReviewStatusWaitGate()
        let model = CloudDriveSyncStatusModel(statusLoader: { _ in
            entered.fulfill()
            await gate.wait()
            return .localOnly
        })
        let item = ContentFile()
        item.url = URL(string: "reader-file://file/load/local/Books/\(UUID().uuidString).epub")!
        item.updateCompoundKey()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView:
            NavigationStack {
                List {
                    Section("My Books") {
                        ForEach([item.compoundKey], id: \.self) { _ in
                            StatusRow(status: model, item: item) { enabled.fulfill() }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        )
        window.isHidden = false
        window.rootViewController?.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(model.status, .loadingStatus)
        await gate.release()
        await fulfillment(of: [enabled], timeout: 3)
        XCTAssertEqual(model.status, .localOnly)
    }
#endif

    func testAlreadyCancelledCallerCannotSupersedeAnActiveRefresh() async {
        let item = ContentFile()
        let readGate = ReviewStatusWaitGate()
        let callerGate = ReviewStatusWaitGate()
        let activeEntered = expectation(description: "active status read entered")
        let cancelledCallerEntered = expectation(description: "old caller waiting before invocation")
        var reads = 0
        let model = CloudDriveSyncStatusModel(statusLoader: { _ in
            reads += 1
            if reads == 1 {
                activeEntered.fulfill()
                await readGate.wait()
                return .availableLocally
            }
            return .cloudOnly
        })
        let old = Task { @MainActor in
            cancelledCallerEntered.fulfill()
            await callerGate.wait()
            await model.refreshAsync(item: item)
        }
        await fulfillment(of: [cancelledCallerEntered], timeout: 3)
        let active = Task { @MainActor in await model.refreshAsync(item: item) }
        await fulfillment(of: [activeEntered], timeout: 3)
        old.cancel()
        await callerGate.release()
        await old.value
        XCTAssertEqual(reads, 1, "An already-cancelled caller must not replace current work")
        await readGate.release()
        await active.value
        XCTAssertEqual(model.status, .availableLocally)
    }

#if os(macOS)
    @MainActor
    private final class Visibility: ObservableObject {
        @Published var shown = true
    }

    @MainActor
    private struct Host: View {
        @ObservedObject var visibility: Visibility
        let item: ContentFile
        let status: CloudDriveSyncStatusModel
        var body: some View {
            Group {
                if visibility.shown {
                    Text("Status lifecycle fixture")
                        .modifier(ReaderFileStatusRefreshModifier(item: item, statusModel: status))
                } else {
                    Text("Removed")
                }
            }
        }
    }

    /// Exercises the real modifier used by ReaderContentInnerListItem. Only
    /// the external status read is suspended; no duplicate lifecycle model.
    func testNotificationReplacementIsCancelledWhenTheRowDisappears() async {
        let firstEntered = expectation(description: "appearance status read")
        let secondEntered = expectation(description: "notification replacement read")
        let secondCancelled = expectation(description: "replacement cancelled on disappearance")
        let gate = ReviewStatusWaitGate()
        var reads = 0
        let model = CloudDriveSyncStatusModel(statusLoader: { _ in
            reads += 1
            let index = reads
            return await withTaskCancellationHandler {
                if index == 1 { firstEntered.fulfill() }
                if index == 2 { secondEntered.fulfill() }
                await gate.wait()
                return .availableLocally
            } onCancel: {
                if index == 2 { secondCancelled.fulfill() }
            }
        })
        let item = ContentFile()
        item.url = URL(string: "reader-file://file/load/local/\(UUID().uuidString).txt")!
        item.updateCompoundKey()
        let visibility = Visibility()
        let host = NSHostingController(rootView: Host(visibility: visibility, item: item, status: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFront(nil)
        await fulfillment(of: [firstEntered], timeout: 3)
        NotificationCenter.default.post(
            name: ReaderFileManager.readerBackingStatusRefreshRequestedNotification,
            object: item.url.absoluteString
        )
        await fulfillment(of: [secondEntered], timeout: 3)
        visibility.shown = false
        await fulfillment(of: [secondCancelled], timeout: 3)
        await gate.release()
        window.close()
        XCTAssertEqual(reads, 2)
    }
#endif
}
