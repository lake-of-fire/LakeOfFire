import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { installBookReadingRuntime } from './book-reading-runtime.js'
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
        this.#postConfirmedPageTurnProgress?.cancel?.();
        this.#postUpdateReadingProgressMessage?.cancel?.();
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
                this.applyBookReadingProgress({
                    ...this.articleReadingProgress,
                    readSegmentIdentifiers: state.readSegmentIdentifiers,
                    sentenceIdentifiersRead: state.sentenceIdentifiersRead,
                    articleMarkedAsFinished: state.finished,
                }, 'native-chapter-publication', true);
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

    #postConfirmedPageTurnProgress = debounce(() => {
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
            bookReadingScope: this.bookReadingRuntime?.captureScope(getPrimaryRendererContent(this.view?.renderer)?.doc) ?? null,
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
        bookReadingScope = null,
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
        if (this.bookReadingRuntime && !this.bookReadingRuntime.isScopeCurrent(bookReadingScope, doc)) return;
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            bookReadingScope,
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
            bookReadingScope: this.bookReadingRuntime?.captureScope(getPrimaryRendererContent(this.view?.renderer)?.doc) ?? null,
                    fraction: Number.isFinite(progressFraction) ? progressFraction : fraction,
                    cfi: persistedLocator,
                    reason,
                    currentPageNumber: typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
                        ? this.navHUD.rendererPageSnapshot.current
                        : null,

