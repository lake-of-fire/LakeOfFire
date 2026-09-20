import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { installBookReadingRuntime } from './book-reading-runtime.js'
import { applyBookReadingProjection } from './book-reading-projection.js'
import { NavigationHUD } from './ebook-viewer-nav.js'
import { processedSectionURLForHref } from './ebook-direct-section.js'
import { copyCustomReaderFontStyleToDocument } from './ebook-font-forwarding.js'
import { ebookProgressFractionForRelocate } from './ebook-reading-progress.js'
import {
    createNativeMarkReadRequestCoordinator,

    #sidebarCloseHandle = null;
    #navButtonOperations = new Set();
    #completionActionSequence = 0;
    bookEndcap = null;
    bookActionBridge = null;
    bookReadingRuntime = null;
    #bookPositionRefreshNeeded = false;
    get isClosed() {
        return this.#closed;
    }
    #isLifecycleCurrent(generation) {
        return !this.#closed && this.#lifecycleGeneration === generation;
    }

            );
            resetRestoreTransactionGlobals();
        }

        this.scheduleGoToPageNumber?.cancel?.();
        this.scheduleGoToFraction?.cancel?.();
        this.#publishConfirmedPageTurnProgress?.cancel?.();
        this.#postUpdateReadingProgressMessage?.cancel?.();
        this.#bookPositionRefreshNeeded = false;
        clearTimeout(this.loadingVisualTimer);
        this.loadingVisualTimer = null;
        clearTimeout(this.#postInitialOpenWorkHandle);
        this.#postInitialOpenWorkHandle = null;
        clearTimeout(this.#sidebarCloseHandle);
        this.#sidebarCloseHandle = null;

            applyProjection: (state, { passChanged }) => {
                if (passChanged) {
                    this.nativeMarkReadRequestCoordinator?.cancelAll('chapter-pass-changed');
                    this.#clearOptimisticMarkReadState('chapter-pass-changed');
                    this.#invalidateVisiblePageSegmentSnapshot('chapter-pass-changed');
                }
                applyBookReadingProjection(this, state, progress =>
                    this.applyBookReadingProgress(progress, 'native-chapter-publication', true));
                if (this.#bookPositionRefreshNeeded && state.scope) {
                    this.#bookPositionRefreshNeeded = false;
                    // Produce a NEW observation of the current admitted location.
                    // Do not attach a new pass to an old queued relocate payload.
                    this.#postConfirmedPageTurnProgress();
                }
                this.refreshNativeLookupHitTargets?.('chapter-pass-publication');
            },
            onVisibility: () => {
                this.#clearOptimisticMarkReadState('book-endcap');
                this.#renderPageTrackingButtons('book-endcap');
                void this.updateNavButtons();

            icon.style.opacity = '';
            icon.style.visibility = '';
            this.#chevronOpacityState[key] = 'hidden';
        });
    }

    #postConfirmedPageTurnProgress = () => {
        const content = getPrimaryRendererContent(this.view?.renderer);
        const doc = content?.doc ?? content?.document ?? null;
        const event = this.bookReadingRuntime?.captureEvent(doc) ?? null;
        this.#publishConfirmedPageTurnProgress(event);
    }
    #publishConfirmedPageTurnProgress = debounce((bookEvent) => {
        if (this.bookReadingRuntime && !this.bookReadingRuntime.isEventCurrent(bookEvent)) return;
        const location = this.view?.lastLocation ?? null;
        const sectionIndex = typeof location?.sectionIndex === 'number'
            ? location.sectionIndex
            : (typeof location?.index === 'number' ? location.index : null);
        const content = getPrimaryRendererContent(this.view?.renderer);
        const doc = content?.doc ?? content?.document ?? null;

            cfiAlreadyUnstable: this.unstableCFIs.has(location?.cfi),
        });
        if (!decision.shouldPost) return;
        if (decision.markCFIUnstable) this.unstableCFIs.add(decision.cfi);
        this.lastCFIPersistenceObservation = decision.nextObservation;
        this.#postUpdateReadingProgressMessage({
            bookEvent,
            fraction: decision.fraction,
            cfi: decision.persistedLocator,
            reason: decision.progressReason,
            currentPageNumber: typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
                ? this.navHUD.rendererPageSnapshot.current
                : null,

        totalPages,
        sectionIndex,
        expectedDocumentURL = null,
        expectedSectionIndex = null,
        expectedLocationCFI = null,
        expectedLocationFraction = null,
        bookEvent = null,
    }) => {
        if (
            this.#closed
            || this.hasLoadedLastPosition !== true
            || globalThis.__manabiRestoreInProgress === true
            || globalThis.__manabiSuppressNextRestoreRelocateSave === true

            expectedDocumentURL,
            expectedSectionIndex,
            currentDocumentURL,
            currentSectionIndex,
        });
        if (this.bookEndcap?.visible) return;
        if (this.bookReadingRuntime && !this.bookReadingRuntime.isEventCurrent(bookEvent)) return;
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            bookReadingScope: bookEvent?.scope ?? null,
            pageURL: currentDocumentURL,
            fractionalCompletion: fraction,
            cfi: cfi,
            reason: reason,
            mainDocumentURL: mainDocumentURL,
            documentStartedAtMs: readerDocumentStartedAtMs(),


    async #onRelocate({
        detail
    }) {
        if (this.#closed) return;
        this.bookReadingRuntime?.updateLocation(true);
        const eventContent = getPrimaryRendererContent(this.view?.renderer);
        const bookEvent = this.bookReadingRuntime?.captureEvent(eventContent?.doc ?? eventContent?.document) ?? null;
        if (this.bookReadingRuntime && !bookEvent && !this.bookEndcap?.visible) {
            this.#bookPositionRefreshNeeded = true;
        }
        const relocateSequence = ++this.#relocateSequence;
        const lifecycleGeneration = this.#lifecycleGeneration;
        const isCurrentRelocate = () => this.#isLifecycleCurrent(lifecycleGeneration)
            && relocateSequence === this.#relocateSequence;
        const {
            fraction,

            const shouldPersistRelocatePosition =
                normalizedRelocateReason !== 'anchor'
                && !shouldSuppressRestoreSettleSave
                && !requiresUserInputBeforePositionSave;
            if (shouldPersistRelocatePosition) {
                this.#postUpdateReadingProgressMessage({
                    bookEvent,
                    fraction: Number.isFinite(progressFraction) ? progressFraction : fraction,
                    cfi: persistedLocator,
                    reason,
                    currentPageNumber: typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
                        ? this.navHUD.rendererPageSnapshot.current
                        : null,

