import AVFoundation
import XCTest
@testable import JapaneseLanguageTools
@testable import LakeOfFireReader

@MainActor
final class ReaderReadAloudSpeechOwnershipTests: XCTestCase {
    func testInitialAdmissionFailurePreservesQueueAndRetryAcquiresOneLease() {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let lease = SpeechOwnershipTestAudioSessionLease()
        var acquisitionCount = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                acquisitionCount += 1
                if acquisitionCount == 1 { throw SpeechOwnershipTestFailure.rejected }
                return lease
            }
        )
        defer { viewModel.clearAITTSPlaybackQueue() }

        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        XCTAssertEqual(acquisitionCount, 1)
        XCTAssertTrue(synthesizer.utterances.isEmpty)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
        XCTAssertEqual(viewModel.ttsUtteranceCount, 2)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "admission-1")
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, 0)
        XCTAssertEqual(lease.releaseCount, 0)

        viewModel.playAITTS()

        XCTAssertEqual(acquisitionCount, 2, "A failed acquisition must leave no held lease that skips retry.")
        XCTAssertEqual(synthesizer.utterances.map(\.speechString), utterances.map(\.text))
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(lease.releaseCount, 0)

        viewModel.stopAITTSIfNeeded()
        viewModel.clearAITTSPlaybackQueue()

        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(lease.releaseCount, 1)
    }

    func testPausedResumeFailureDoesNotContinueAndRetryPreservesPreparedQueue() {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let firstLease = SpeechOwnershipTestAudioSessionLease()
        let resumedLease = SpeechOwnershipTestAudioSessionLease()
        var acquisitionCount = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                acquisitionCount += 1
                if acquisitionCount == 2 { throw SpeechOwnershipTestFailure.rejected }
                return acquisitionCount == 1 ? firstLease : resumedLease
            }
        )
        defer { viewModel.clearAITTSPlaybackQueue() }
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        let generation = viewModel.ttsQueueGeneration
        let queuedUtterances = synthesizer.utterances

        viewModel.pauseAITTS()

        XCTAssertTrue(synthesizer.isPaused)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(firstLease.releaseCount, 1)

        viewModel.playAITTS()

        XCTAssertEqual(acquisitionCount, 2)
        XCTAssertEqual(synthesizer.continueCount, 0)
        XCTAssertTrue(synthesizer.isPaused)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
        XCTAssertEqual(viewModel.ttsQueueGeneration, generation)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "admission-1")
        XCTAssertEqual(synthesizer.utterances.count, queuedUtterances.count)
        XCTAssertEqual(resumedLease.releaseCount, 0)

        viewModel.playAITTS()

        XCTAssertEqual(acquisitionCount, 3)
        XCTAssertEqual(synthesizer.continueCount, 1)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertFalse(synthesizer.isPaused)
        XCTAssertEqual(synthesizer.utterances.count, queuedUtterances.count)
        XCTAssertEqual(viewModel.ttsQueueGeneration, generation)

        viewModel.clearAITTSPlaybackQueue()
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(resumedLease.releaseCount, 1)
    }

    func testObsoleteQueueCallbacksDoNotReleaseReplacementLeaseOrPublishCompletion() throws {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let firstLease = SpeechOwnershipTestAudioSessionLease()
        let replacementLease = SpeechOwnershipTestAudioSessionLease()
        var acquisitionCount = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                acquisitionCount += 1
                return acquisitionCount == 1 ? firstLease : replacementLease
            }
        )
        defer { viewModel.clearAITTSPlaybackQueue() }
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        let obsoleteUtterance = try XCTUnwrap(synthesizer.utterances.first)
        let completionGeneration = viewModel.ttsPlaybackCompletionGeneration

        XCTAssertTrue(viewModel.presentAITTS(
            utterances: [ReaderTTSUtterance(sentenceIdentifier: "replacement", text: "次の文章です。")],
            autoplay: true
        ))
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(acquisitionCount, 2)

        let callbackSynthesizer = AVSpeechSynthesizer()
        viewModel.speechSynthesizer(callbackSynthesizer, didFinish: obsoleteUtterance)
        viewModel.speechSynthesizer(callbackSynthesizer, didCancel: obsoleteUtterance)

        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "replacement")
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completionGeneration)
        XCTAssertEqual(replacementLease.releaseCount, 0)

        viewModel.stopAITTSIfNeeded()
        viewModel.clearAITTSPlaybackQueue()

        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(replacementLease.releaseCount, 1)
    }

#if DEBUG
    func testStoppingReadAloudPreservesAnotherSharedAudioOwner() throws {
        ManabiSpokenAudioSession.resetForTesting()
        defer { ManabiSpokenAudioSession.resetForTesting() }
        var activations = [ManabiSpokenAudioIntent]()
        var deactivationCount = 0
        ManabiSpokenAudioSession.activationOverrideForTesting = { activations.append($0) }
        ManabiSpokenAudioSession.deactivationOverrideForTesting = { deactivationCount += 1 }
        let recordedAudioLease = try ManabiSpokenAudioSession.acquire(.recordedAudio)
        defer { try? recordedAudioLease.release() }
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer)
        )
        defer { viewModel.clearAITTSPlaybackQueue() }

        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        XCTAssertEqual(ManabiSpokenAudioSession.activeLeaseCountForTesting, 2)
        XCTAssertEqual(activations, [.recordedAudio])

        viewModel.stopAITTSIfNeeded()
        viewModel.clearAITTSPlaybackQueue()

        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(ManabiSpokenAudioSession.activeLeaseCountForTesting, 1)
        XCTAssertEqual(deactivationCount, 0)

        try recordedAudioLease.release()
        XCTAssertEqual(ManabiSpokenAudioSession.activeLeaseCountForTesting, 0)
        XCTAssertEqual(deactivationCount, 1)
    }
#endif


    func testPausedSeekRejectsTerminalFinishDeliveredSynchronouslyByStop() throws {
        try checkPausedSeekStopCallback(finish: true)
    }

    func testPausedSeekRejectsStopCancellationAndLaterOldCallbacks() throws {
        try checkPausedSeekStopCallback(finish: false)
    }

    private func checkPausedSeekStopCallback(finish: Bool) throws {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let lease = SpeechOwnershipTestAudioSessionLease()
        let resumedLease = SpeechOwnershipTestAudioSessionLease()
        var acquisitions = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                acquisitions += 1
                return acquisitions == 1 ? lease : resumedLease
            }
        )
        defer { viewModel.clearAITTSPlaybackQueue() }
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        let first = try XCTUnwrap(synthesizer.utterances.first)
        let terminal = try XCTUnwrap(synthesizer.utterances.last)
        viewModel.pauseAITTS()
        XCTAssertTrue(synthesizer.isPaused)
        XCTAssertEqual(lease.releaseCount, 1)
        let completed = viewModel.ttsPlaybackCompletionGeneration
        var stopCallbackCount = 0
        synthesizer.onStop = { [weak viewModel] in
            stopCallbackCount += 1
            guard let viewModel else { return }
            let callbackSource = AVSpeechSynthesizer()
            if finish {
                viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
            } else {
                viewModel.speechSynthesizer(callbackSource, didCancel: first)
            }
        }

        viewModel.seekAITTS(toSentenceIdentifier: "admission-2", shouldPlay: false)

        XCTAssertEqual(stopCallbackCount, 1, "The regression must reenter the real delegate during stop.")
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "admission-2")
        XCTAssertEqual(viewModel.ttsProgressValue, 1)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completed)
        let countAfterSeek = synthesizer.utterances.count
        let callbackSource = AVSpeechSynthesizer()
        viewModel.speechSynthesizer(callbackSource, didStart: first)
        viewModel.speechSynthesizer(callbackSource,
                                  willSpeakRangeOfSpeechString: NSRange(location: 1, length: 1),
                                  utterance: first)
        viewModel.speechSynthesizer(callbackSource, didContinue: first)
        viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
        viewModel.speechSynthesizer(callbackSource, didCancel: terminal)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "admission-2")
        XCTAssertEqual(viewModel.ttsProgressValue, 1)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completed)
        XCTAssertEqual(synthesizer.utterances.count, countAfterSeek)
        XCTAssertEqual(lease.releaseCount, 1)

        viewModel.playAITTS()
        XCTAssertEqual(acquisitions, 2)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(synthesizer.utterances.count, countAfterSeek + 1)
        let current = try XCTUnwrap(synthesizer.utterances.last)
        XCTAssertFalse(current === terminal)
        viewModel.speechSynthesizer(callbackSource, didFinish: current)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completed + 1)
        XCTAssertEqual(lease.releaseCount, 1)
        XCTAssertEqual(resumedLease.releaseCount, 1)
    }

    func testFailedPausedResumeRejectsDelayedPositiveCallbacksUntilLeaseRetry() throws {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let firstLease = SpeechOwnershipTestAudioSessionLease()
        let resumedLease = SpeechOwnershipTestAudioSessionLease()
        var acquisitions = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                acquisitions += 1
                if acquisitions == 2 { throw SpeechOwnershipTestFailure.rejected }
                return acquisitions == 1 ? firstLease : resumedLease
            }
        )
        defer { viewModel.clearAITTSPlaybackQueue() }
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        let delayed = try XCTUnwrap(synthesizer.utterances.last)
        viewModel.pauseAITTS()
        let progress = viewModel.ttsProgressValue
        let sentence = viewModel.ttsCurrentSentenceIdentifier
        let generation = viewModel.ttsQueueGeneration
        let completion = viewModel.ttsPlaybackCompletionGeneration
        viewModel.playAITTS()
        XCTAssertEqual(acquisitions, 2)
        XCTAssertEqual(synthesizer.continueCount, 0)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertTrue(synthesizer.isPaused)
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(resumedLease.releaseCount, 0)

        let callbackSource = AVSpeechSynthesizer()
        viewModel.speechSynthesizer(callbackSource, didStart: delayed)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, sentence)
        XCTAssertEqual(viewModel.ttsProgressValue, progress)
        viewModel.speechSynthesizer(callbackSource,
                                  willSpeakRangeOfSpeechString: NSRange(location: 1, length: 1),
                                  utterance: delayed)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, sentence)
        XCTAssertEqual(viewModel.ttsProgressValue, progress)
        viewModel.speechSynthesizer(callbackSource, didContinue: delayed)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsQueueGeneration, generation)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
        XCTAssertEqual(resumedLease.releaseCount, 0)

        viewModel.playAITTS()
        XCTAssertEqual(acquisitions, 3)
        XCTAssertEqual(synthesizer.continueCount, 1)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(synthesizer.utterances.count, 2)
        // The same physical utterance remains valid after a successful lease retry.
        viewModel.speechSynthesizer(callbackSource, didStart: delayed)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "admission-2")
        viewModel.speechSynthesizer(callbackSource,
                                  willSpeakRangeOfSpeechString: NSRange(location: 1, length: 1),
                                  utterance: delayed)
        XCTAssertGreaterThan(viewModel.ttsProgressValue, 1)
        viewModel.speechSynthesizer(callbackSource, didPause: delayed)
        XCTAssertFalse(viewModel.isPlaying)
        viewModel.speechSynthesizer(callbackSource, didContinue: delayed)
        XCTAssertTrue(viewModel.isPlaying)
        viewModel.clearAITTSPlaybackQueue()
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(resumedLease.releaseCount, 1)
    }

    func testCurrentCompletionAdvancesOnceAndDuplicateCallbacksAreInert() throws {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let lease = SpeechOwnershipTestAudioSessionLease()
        let viewModel = makeModel(synthesizer: synthesizer, lease: lease)
        defer { viewModel.clearAITTSPlaybackQueue() }
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        let first = try XCTUnwrap(synthesizer.utterances.first)
        let terminal = try XCTUnwrap(synthesizer.utterances.last)
        let completion = viewModel.ttsPlaybackCompletionGeneration
        let callbackSource = AVSpeechSynthesizer()
        viewModel.speechSynthesizer(callbackSource, didFinish: first)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "admission-2")
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
        XCTAssertEqual(lease.releaseCount, 0)
        viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsProgressValue, viewModel.ttsProgressUpperBound)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion + 1)
        XCTAssertEqual(lease.releaseCount, 1)
        viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
        viewModel.speechSynthesizer(callbackSource, didCancel: terminal)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion + 1)
        XCTAssertEqual(lease.releaseCount, 1)
    }

    func testObsoleteCallbacksCannotRefillReplacementWindowButCurrentFinishDoes() throws {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let firstLease = SpeechOwnershipTestAudioSessionLease()
        let replacementLease = SpeechOwnershipTestAudioSessionLease()
        var acquisitions = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                acquisitions += 1
                return acquisitions == 1 ? firstLease : replacementLease
            }
        )
        defer { viewModel.clearAITTSPlaybackQueue() }
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        let obsolete = try XCTUnwrap(synthesizer.utterances.first)
        let replacement = (0..<10).map {
            ReaderTTSUtterance(sentenceIdentifier: "window-\($0)", text: "窓の文章\($0)です。")
        }
        XCTAssertTrue(viewModel.presentAITTS(utterances: replacement, autoplay: true))
        XCTAssertEqual(acquisitions, 2)
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(synthesizer.utterances.count, 10) // Old2 plus current window8.
        let firstCurrent = synthesizer.utterances[2]
        let completion = viewModel.ttsPlaybackCompletionGeneration
        let callbackSource = AVSpeechSynthesizer()
        viewModel.speechSynthesizer(callbackSource, didFinish: obsolete)
        viewModel.speechSynthesizer(callbackSource, didCancel: obsolete)
        XCTAssertEqual(synthesizer.utterances.count, 10)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "window-0")
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
        XCTAssertEqual(replacementLease.releaseCount, 0)
        viewModel.speechSynthesizer(callbackSource, didFinish: firstCurrent)
        XCTAssertEqual(synthesizer.utterances.count, 11)
        XCTAssertEqual(synthesizer.utterances.last?.speechString, replacement[8].text)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "window-1")
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
        XCTAssertEqual(replacementLease.releaseCount, 0)
        viewModel.speechSynthesizer(callbackSource, didFinish: firstCurrent)
        XCTAssertEqual(synthesizer.utterances.count, 11)
    }

    func testCurrentCancellationStillStopsCurrentPlaybackWithoutInventingCompletion() throws {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let lease = SpeechOwnershipTestAudioSessionLease()
        let viewModel = makeModel(synthesizer: synthesizer, lease: lease)
        defer { viewModel.clearAITTSPlaybackQueue() }
        XCTAssertTrue(viewModel.presentAITTS(
            utterances: [utterances[0]], autoplay: true))
        let current = try XCTUnwrap(synthesizer.utterances.first)
        let completion = viewModel.ttsPlaybackCompletionGeneration
        viewModel.speechSynthesizer(AVSpeechSynthesizer(), didCancel: current)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertTrue(viewModel.hasPreparedAITTS)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
        viewModel.clearAITTSPlaybackQueue()
        XCTAssertEqual(lease.releaseCount, 1)
    }

    func testDelayedFinishAfterRefusedResumeDefersRefillUntilSuccessfulLeaseRetry() throws {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let firstLease = SpeechOwnershipTestAudioSessionLease()
        let resumedLease = SpeechOwnershipTestAudioSessionLease()
        var acquisitions = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                acquisitions += 1
                if acquisitions == 2 { throw SpeechOwnershipTestFailure.rejected }
                return acquisitions == 1 ? firstLease : resumedLease
            }
        )
        defer { viewModel.clearAITTSPlaybackQueue() }
        let queue = (0..<10).map {
            ReaderTTSUtterance(sentenceIdentifier: "refill-\($0)", text: "続きの文章\($0)です。")
        }
        XCTAssertTrue(viewModel.presentAITTS(utterances: queue, autoplay: true))
        XCTAssertEqual(synthesizer.utterances.count, 8)
        let originalWindow = synthesizer.utterances
        let first = try XCTUnwrap(originalWindow.first)
        let next = try XCTUnwrap(originalWindow.dropFirst().first)
        let generation = viewModel.ttsQueueGeneration
        let completion = viewModel.ttsPlaybackCompletionGeneration
        viewModel.pauseAITTS()
        XCTAssertTrue(synthesizer.isPaused)
        XCTAssertEqual(firstLease.releaseCount, 1)
        viewModel.playAITTS()
        XCTAssertEqual(acquisitions, 2)
        XCTAssertEqual(synthesizer.continueCount, 0)
        XCTAssertEqual(synthesizer.utterances.count, 8)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(resumedLease.releaseCount, 0)

        let callbackSource = AVSpeechSynthesizer()
        viewModel.speechSynthesizer(callbackSource, didFinish: first)
        XCTAssertEqual(synthesizer.utterances.count, 8, "A delayed finish cannot enqueue speech without a lease.")
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "refill-1")
        XCTAssertEqual(viewModel.ttsProgressValue, 1)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
        viewModel.speechSynthesizer(callbackSource, didFinish: first)
        XCTAssertEqual(synthesizer.utterances.count, 8)
        XCTAssertEqual(viewModel.ttsProgressValue, 1)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)

        viewModel.playAITTS()
        XCTAssertEqual(acquisitions, 3)
        XCTAssertEqual(synthesizer.continueCount, 1)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(synthesizer.utterances.count, 9, "A successful resume must fill the slot deferred while unleased.")
        XCTAssertEqual(synthesizer.utterances.last?.speechString, queue[8].text)
        XCTAssertEqual(viewModel.ttsQueueGeneration, generation)
        for index in 1..<8 {
            XCTAssertTrue(synthesizer.utterances[index] === originalWindow[index])
        }
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(resumedLease.releaseCount, 0)

        viewModel.speechSynthesizer(callbackSource, didFinish: next)
        XCTAssertEqual(synthesizer.utterances.count, 10)
        XCTAssertEqual(synthesizer.utterances.last?.speechString, queue[9].text)
        XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "refill-2")
        XCTAssertEqual(viewModel.ttsProgressValue, 2)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
        XCTAssertEqual(viewModel.ttsQueueGeneration, generation)
        viewModel.clearAITTSPlaybackQueue()
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(resumedLease.releaseCount, 1)
    }

    func testCompletionReceiptBelongsToQueueAndReplayPublishesAnotherCycleOnce() throws {
        let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
        let firstLease = SpeechOwnershipTestAudioSessionLease()
        let replayLease = SpeechOwnershipTestAudioSessionLease()
        var acquisitions = 0
        let viewModel = ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: {
                acquisitions += 1
                return acquisitions == 1 ? firstLease : replayLease
            })
        defer { viewModel.clearAITTSPlaybackQueue() }
        XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
        let queueGeneration = viewModel.ttsQueueGeneration
        let completion = viewModel.ttsPlaybackCompletionGeneration
        let first = try XCTUnwrap(synthesizer.utterances.first)
        let terminal = try XCTUnwrap(synthesizer.utterances.last)
        let callbackSource = AVSpeechSynthesizer()
        XCTAssertNil(viewModel.ttsPlaybackCompletedQueueGeneration)

        viewModel.speechSynthesizer(callbackSource, didFinish: first)
        XCTAssertNil(viewModel.ttsPlaybackCompletedQueueGeneration)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
        viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
        XCTAssertEqual(viewModel.ttsPlaybackCompletedQueueGeneration, queueGeneration)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion + 1)
        XCTAssertEqual(firstLease.releaseCount, 1)
        viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
        viewModel.speechSynthesizer(callbackSource, didCancel: terminal)
        XCTAssertEqual(viewModel.ttsPlaybackCompletedQueueGeneration, queueGeneration)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion + 1)

        viewModel.playAITTS()
        XCTAssertEqual(acquisitions, 2)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsQueueGeneration, queueGeneration)
        XCTAssertNil(viewModel.ttsPlaybackCompletedQueueGeneration,
                     "Replay retains queue identity but retires the previous cycle's receipt")
        XCTAssertEqual(synthesizer.utterances.count, 4)
        let replayFirst = synthesizer.utterances[2]
        let replayTerminal = synthesizer.utterances[3]
        XCTAssertFalse(replayFirst === first)
        XCTAssertFalse(replayTerminal === terminal)
        viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
        viewModel.speechSynthesizer(callbackSource, didCancel: first)
        XCTAssertNil(viewModel.ttsPlaybackCompletedQueueGeneration)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion + 1)
        XCTAssertTrue(viewModel.isPlaying)
        XCTAssertEqual(replayLease.releaseCount, 0)

        viewModel.speechSynthesizer(callbackSource, didFinish: replayFirst)
        XCTAssertNil(viewModel.ttsPlaybackCompletedQueueGeneration)
        viewModel.speechSynthesizer(callbackSource, didFinish: replayTerminal)
        XCTAssertFalse(viewModel.isPlaying)
        XCTAssertEqual(viewModel.ttsPlaybackCompletedQueueGeneration, queueGeneration)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion + 2)
        XCTAssertEqual(replayLease.releaseCount, 1)
        viewModel.speechSynthesizer(callbackSource, didFinish: replayTerminal)
        viewModel.speechSynthesizer(callbackSource, didCancel: replayTerminal)
        XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion + 2)
        XCTAssertEqual(firstLease.releaseCount, 1)
        XCTAssertEqual(replayLease.releaseCount, 1)
    }

    func testPausedSeekRetiresHeldPreparationAndCompletionReceiptBeforeStopReentry() throws {
        for completedBeforeSeek in [false, true] {
            let synthesizer = SpeechOwnershipTestSpeechSynthesizer()
            let firstLease = SpeechOwnershipTestAudioSessionLease()
            let resumedLease = SpeechOwnershipTestAudioSessionLease()
            var acquisitions = 0
            let viewModel = ReaderMediaPlayerViewModel(
                readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
                readAloudAudioSessionLeaseFactory: {
                    acquisitions += 1
                    return acquisitions == 1 ? firstLease : resumedLease
                })
            defer { viewModel.clearAITTSPlaybackQueue() }
            XCTAssertTrue(viewModel.presentAITTS(utterances: utterances, autoplay: true))
            let terminal = try XCTUnwrap(synthesizer.utterances.last)
            let callbackSource = AVSpeechSynthesizer()
            if completedBeforeSeek {
                viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
                XCTAssertEqual(viewModel.ttsPlaybackCompletedQueueGeneration, viewModel.ttsQueueGeneration)
            } else {
                viewModel.pauseAITTS()
                XCTAssertTrue(synthesizer.isPaused)
            }
            XCTAssertEqual(firstLease.releaseCount, 1)
            let heldPreparation = try XCTUnwrap(viewModel.beginReadAloudPreparation())
            XCTAssertTrue(viewModel.isCurrentReadAloudPreparation(heldPreparation))
            let queueGeneration = viewModel.ttsQueueGeneration
            let completion = viewModel.ttsPlaybackCompletionGeneration
            let queuedCount = synthesizer.utterances.count
            var stopCallbacks = 0
            synthesizer.onStop = { [weak viewModel] in
                stopCallbacks += 1
                guard let viewModel else { return }
                XCTAssertFalse(viewModel.isCurrentReadAloudPreparation(heldPreparation))
                XCTAssertNil(viewModel.ttsPlaybackCompletedQueueGeneration)
                viewModel.speechSynthesizer(callbackSource, didFinish: terminal)
                viewModel.completeReadAloudPreparation(heldPreparation)
            }

            viewModel.seekAITTS(toSentenceIdentifier: "admission-2", shouldPlay: false)

            XCTAssertEqual(stopCallbacks, 1)
            XCTAssertFalse(viewModel.isPlaying)
            XCTAssertTrue(viewModel.hasPreparedAITTS)
            XCTAssertFalse(viewModel.isPreparingReadAloud)
            XCTAssertFalse(viewModel.isCurrentReadAloudPreparation(heldPreparation))
            XCTAssertNil(viewModel.ttsPlaybackCompletedQueueGeneration)
            XCTAssertEqual(viewModel.ttsQueueGeneration, queueGeneration)
            XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion)
            XCTAssertEqual(viewModel.ttsCurrentSentenceIdentifier, "admission-2")
            XCTAssertEqual(viewModel.ttsProgressValue, 1)
            XCTAssertEqual(synthesizer.utterances.count, queuedCount)
            XCTAssertEqual(acquisitions, 1)

            let freshPreparation = try XCTUnwrap(viewModel.beginReadAloudPreparation())
            viewModel.completeReadAloudPreparation(heldPreparation)
            viewModel.failReadAloudPreparation(heldPreparation, message: "retired continuation")
            XCTAssertTrue(viewModel.isCurrentReadAloudPreparation(freshPreparation))
            XCTAssertNil(viewModel.readAloudErrorMessage)
            viewModel.cancelReadAloudPreparation()
            viewModel.playAITTS()
            XCTAssertEqual(acquisitions, 2)
            XCTAssertTrue(viewModel.isPlaying)
            XCTAssertEqual(synthesizer.utterances.count, queuedCount + 1)
            let current = try XCTUnwrap(synthesizer.utterances.last)
            XCTAssertFalse(current === terminal)
            viewModel.speechSynthesizer(callbackSource, didFinish: current)
            XCTAssertFalse(viewModel.isPlaying)
            XCTAssertEqual(viewModel.ttsPlaybackCompletedQueueGeneration, queueGeneration)
            XCTAssertEqual(viewModel.ttsPlaybackCompletionGeneration, completion + 1)
            XCTAssertEqual(firstLease.releaseCount, 1)
            XCTAssertEqual(resumedLease.releaseCount, 1)
        }
    }

    private func makeModel(
        synthesizer: SpeechOwnershipTestSpeechSynthesizer,
        lease: SpeechOwnershipTestAudioSessionLease
    ) -> ReaderMediaPlayerViewModel {
        ReaderMediaPlayerViewModel(
            readAloudController: ReaderReadAloudController(synthesizer: synthesizer),
            readAloudAudioSessionLeaseFactory: { lease })
    }

    private var utterances: [ReaderTTSUtterance] {
        [
            ReaderTTSUtterance(sentenceIdentifier: "admission-1", text: "一文目です。"),
            ReaderTTSUtterance(sentenceIdentifier: "admission-2", text: "二文目です。"),
        ]
    }
}

private enum SpeechOwnershipTestFailure: Error {
    case rejected
}

@MainActor
private final class SpeechOwnershipTestAudioSessionLease: ReaderReadAloudAudioSessionLease {
    private(set) var releaseCount = 0

    func release() throws {
        releaseCount += 1
    }
}

@MainActor
private final class SpeechOwnershipTestSpeechSynthesizer: ReaderSpeechSynthesizing {
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private(set) var utterances = [AVSpeechUtterance]()
    private(set) var continueCount = 0
    var onStop: (() -> Void)?

    func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
        isSpeaking = true
        isPaused = false
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        let wasActive = isSpeaking || isPaused
        let callback = onStop
        onStop = nil
        callback?()
        isSpeaking = false
        isPaused = false
        return wasActive
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        guard isSpeaking else { return false }
        isSpeaking = false
        isPaused = true
        return true
    }

    func continueSpeaking() -> Bool {
        continueCount += 1
        guard isPaused else { return false }
        isSpeaking = true
        isPaused = false
        return true
    }
}
