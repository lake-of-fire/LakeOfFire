        this.#bindGlobal(window, 'manabiCancelPendingMarkReadPresentation', requestID => {
            if (typeof requestID !== 'string' || !requestID
                || this.pendingMarkReadPresentation?.requestID !== requestID) return false
            this.pendingMarkReadPresentation = null
            this.pageTrackingBusyStateIDs.clear()
            this.pageTrackingAnimateReadStateIDs.clear();
            return true;
        });
    async #submitMarkReadPayload(payload, {
        sectionID,
        owner,
        reason,
        animateStateID = null,
    }) {
        const validatedPayload = this.#validatedMarkReadPayload(payload);
        if (!validatedPayload) {
            this.lastNativeMarkReadRequestOutcome = 'failed';
            this.lastNativeMarkReadRequestErrorCode = 'invalidPayload';
            return { success: false, errorCode: 'invalidPayload', permitsAutoAdvance: false, presentation: null }
        }
        // One transient continuation owner, not synchronized state. A new
        // request or native cancellation retires the preceding repaint/advance.
        const presentation = { owner };
        this.pendingMarkReadPresentation = presentation;
        const outcome = await this.nativeMarkReadRequestCoordinator.request({
            sectionID,
            owner,
            onRequestID: requestID => { presentation.requestID = requestID },
            context: { payload: validatedPayload, reason, animateStateID },
            message: {
                ...validatedPayload,
                topWindowURL: window.top.location.href,
                pageURL: owner?.document?.location?.href ?? null,
                documentStartedAtMs: Number.isFinite(window.top?.performance?.timeOrigin)
                    ? window.top.performance.timeOrigin
                    : readerDocumentStartedAtMs(),
            },
        });
        if (this.pendingMarkReadPresentation === presentation) {
            this.lastNativeMarkReadRequestOutcome = outcome.success === true ? 'committed' : 'failed';
            this.lastNativeMarkReadRequestErrorCode = outcome.errorCode ?? '';
        }
        let presented = false
        try {
            presented = outcome.success === true && outcome.stale !== true
                && this.#isMarkReadPresentationCurrent(presentation)
                && this.#applyCommittedMarkReadPayload(validatedPayload, outcome.nativeResult, reason, animateStateID)
        } catch (error) {
            // The native write already committed. A renderer failure may deny
            // presentation, but must not turn the saved Mark into failed Finish.
            console.error('Committed Mark presentation failed', error)
        }
        return {
            success: outcome.success === true,
            requestID: outcome.requestID,
            errorCode: outcome.errorCode,
            permitsAutoAdvance: presented && outcome.nativeResult?.isMarked === true
                && outcome.nativeResult?.permitsAutoAdvance === true,
            presentation: presented ? presentation : null,
        };
    }
    applyMarkSectionAsReadResult(result) {
        return this.nativeMarkReadRequestCoordinator?.settle?.(result) ?? false;
    }
    async markAllSectionsAsRead() {
        const payload = this.buildMarkAllSectionsAsReadPayload();
        const doc = getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
        if (!payload || !isDocumentLike(doc)) {
            throw new Error('nativeMarkReadPreparationUnavailable')
        }
        const outcome = await this.#submitMarkReadPayload(payload, {
            sectionID: `ebook-mark-all:${this.#lifecycleGeneration}`,
            owner: this.#markReadOwner({ document: doc }),
            reason: 'native-mark-all-read-committed',
        });
        if (!outcome.success) {
            throw new Error(outcome.errorCode || 'nativeCommitFailed')
        }
        // A committed Mark retains its result even after cancellation or when
        // native presentation is denied. Only the outer native Finish navigates.
        return payload.segments.length || payload.sentenceIdentifiers.length
    }
    async #markPageClusterAsRead(stateID) {
        const pageTrackingState = this.pageTrackingStates.find((state) => state.id === stateID);
        if (!pageTrackingState || this.pageTrackingBusyStateIDs.has(stateID)) {
            return false;
        }
        if (pageTrackingState.payload.segments.length === 0
            && pageTrackingState.payload.sentenceIdentifiers.length === 0) {
            return false;
        }
        if (pageTrackingState.isRead) {
            return true;
        }
        const doc = this.#currentPageTrackingDocument();
        if (!isDocumentLike(doc)) return false;
        const advanceOwner = {
            lifecycleGeneration: this.#lifecycleGeneration,
            renderer: this.view?.renderer ?? null,
            visiblePageCollectionGeneration: this.visiblePageCollectionGeneration,
        };
        const previousPresentation = this.pendingMarkReadPresentation
        let outcome = null
        this.lastNativeMarkReadRequestOutcome = 'pending';
        this.pageTrackingBusyStateIDs.add(stateID);
        try {
            this.#renderPageTrackingButtons('mark-read-busy');
            outcome = await this.#submitMarkReadPayload(pageTrackingState.payload, {
                sectionID: `ebook-page:${stateID}:${this.visiblePageCollectionGeneration}`,
                owner: this.#markReadOwner({
                    document: doc,
                    requireVisibleGeneration: true,
                }),
                reason: 'native-mark-read-committed',
                animateStateID: stateID,
            });
            if (!outcome.success) return false;
            if (outcome.permitsAutoAdvance) {
                await this.#advanceAfterMarkRead({
                    ...advanceOwner, presentation: outcome.presentation, permitsAutoAdvance: true,
                });
            }
            return true;
        } catch (error) {
            if (outcome?.success !== true) throw error
            // Navigation is presentation too; a saved Mark remains successful.
            console.error('Committed Mark navigation failed', error)
            return true
        } finally {
            try {
                const presentation = this.pendingMarkReadPresentation
                const ownsCleanup = outcome?.requestID
                    ? presentation?.requestID === outcome.requestID
                    : presentation === previousPresentation
                if (ownsCleanup
                    && this.#isRendererLifecycleCurrent(advanceOwner.lifecycleGeneration, advanceOwner.renderer)
                    && this.#currentPageTrackingDocument(doc) === doc) {
                    this.pageTrackingBusyStateIDs.delete(stateID)
                    this.#renderPageTrackingButtons('mark-read-finished')
                }
            } catch (error) {
                // Neither renderer cleanup nor an ownership probe may replace
                // the persistence result (or its original pre-commit error).
                console.error('Mark Read presentation cleanup failed', error)
            }
        }
    }
    async markVisiblePageAsRead(source = 'native') {
        const completionAction = this.completionAction;
        if (completionAction) {
            if (this.completionActionBusy) {
                return false;
            }
window.manabiReadAloudAdvanceToNextSection = async () => {
    const reader = globalThis.reader;
    const renderer = reader?.view?.renderer;
    const isCurrentRenderer = () => globalThis.reader === reader
        && reader?.isClosed !== true
        && reader?.view?.renderer === renderer;
    return await advanceCurrentRendererSection({
        renderer,
        getCurrentIndex: () => getPrimaryRendererContentIndex(renderer),
        isCurrent: isCurrentRenderer,
    });
}

window.manabi_markAllSectionsAsRead = async () => {
    const reader = globalThis.reader
    if (!reader || reader.isClosed === true || typeof reader.markAllSectionsAsRead !== 'function') {
        throw new Error('nativeMarkReadPreparationUnavailable')
    }
    return await reader.markAllSectionsAsRead()
}

window.manabi_buildMarkAllSectionsAsReadPayload = () => {
    return globalThis.reader?.buildMarkAllSectionsAsReadPayload?.() ?? null;
}

window.manabi_applyCommittedMarkAllSectionsAsReadPayload = (payload) => {
    return globalThis.reader?.applyCommittedMarkAllSectionsAsReadPayload?.(payload) ?? 0;
}
