        this.#bindGlobal(window, 'manabi_markVisiblePageAsRead', async (source = 'native') => {
            return await this.markVisiblePageAsRead(source);
        });
        // Native Undo awaits this exact document's cancellation before its write.
        // Do not cancel the persistence request: its real result must still settle.
        this.#bindGlobal(window, 'manabiCancelPendingMarkReadPresentation', () => {
            this.pendingMarkReadPresentation = null;
            this.pageTrackingAnimateReadStateIDs.clear();
            return true;
        });
        this.#listen(window, 'resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
        this.#listen(window.visualViewport, 'resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
    applyBookReadingProgress(articleReadingProgress, _reason = 'unspecified') {
        const incomingProgress = normalizeArticleReadingProgress(articleReadingProgress);
        // Native snapshots may decrease after Undo/reset. A previous Mark's
        // rendering cache must never be unioned back into authoritative state.
        this.optimisticReadSegmentIdentifiers.clear();
        this.optimisticSentenceIdentifiersRead.clear();
        this.articleReadingProgress = incomingProgress;
        this.markedAsFinished = !!this.articleReadingProgress.articleMarkedAsFinished;
        this.lastPageTrackingStateSignature = null;
        this.lastPageTrackingStateSnapshot = null;
        return {
            ...payload,
            segments: Array.from(stableSegments.values()),
            sentenceIdentifiers,
        };
    }
    #isMarkReadPresentationCurrent(presentation) {
        const owner = presentation?.owner;
        return this.pendingMarkReadPresentation === presentation && !!owner
            && this.#isRendererLifecycleCurrent(owner.lifecycleGeneration, owner.renderer)
            && (!owner.document
                || getCurrentRendererDocument(owner.renderer, owner.document) === owner.document)
            && (!owner.requireVisibleGeneration
                || this.visiblePageCollectionGeneration === owner.visiblePageCollectionGeneration);
    }
    #applyCommittedMarkReadPayload(payload, nativeResult, reason, animateStateID = null) {
        const validatedPayload = this.#validatedMarkReadPayload(payload);
        const presentation = this.pendingMarkReadPresentation;
        if (!validatedPayload || nativeResult?.success !== true
            || nativeResult.permitsPresentation !== true
            || !this.#isMarkReadPresentationCurrent(presentation)
            || typeof presentation.requestID !== 'string'
            || nativeResult.requestID !== presentation.requestID) return false;
        const sequence = nativeResult.stateSnapshotSequence;
        if (!Number.isSafeInteger(sequence) || sequence <= 0
            || sequence <= (this.lastAppliedMarkReadStateSequence ?? 0)) return false;
        const requestedSegments = new Set(validatedPayload.segments.map(segment => segment.stableSegmentID));
        const requestedSentences = new Set(validatedPayload.sentenceIdentifiers);
        const effectiveSegments = nativeResult.displayEffectiveStableSegmentIDs;
        const effectiveSentences = nativeResult.displayEffectiveStableSentenceIDs;
        const isScopedSet = (values, requested) => Array.isArray(values)
            && new Set(values).size === values.length
            && values.every(value => typeof value === 'string' && value.length > 0 && requested.has(value));
        if (!isScopedSet(effectiveSegments, requestedSegments)
            || !isScopedSet(effectiveSentences, requestedSentences)) return false;
        // Replace only the subjects covered by this native snapshot. Requested
        // selection is not proof of reading, and no optimistic support is retained.
        const progress = normalizeArticleReadingProgress(this.articleReadingProgress);
        progress.readSegmentIdentifiers = Array.from(new Set([
            ...progress.readSegmentIdentifiers.filter(id => !requestedSegments.has(id)),
            ...effectiveSegments,
        ]));
        progress.sentenceIdentifiersRead = Array.from(new Set([
            ...progress.sentenceIdentifiersRead.filter(id => !requestedSentences.has(id)),
            ...effectiveSentences,
        ]));
        this.lastAppliedMarkReadStateSequence = sequence;
        if (animateStateID && nativeResult.isMarked === true) {
            this.pageTrackingAnimateReadStateIDs.add(animateStateID);
        }
        this.applyBookReadingProgress(progress, reason);
        return true;
    }
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
            return { success: false, permitsAutoAdvance: false, presentation: null };
        }
        // One transient continuation owner, not synchronized state. A new
        // request or native cancellation retires the preceding repaint/advance.
        const presentation = { owner };
        this.pendingMarkReadPresentation = presentation;
        const outcome = await this.nativeMarkReadRequestCoordinator.request({
            sectionID,
            owner,
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
        presentation.requestID = outcome.requestID;
        if (this.pendingMarkReadPresentation === presentation) {
            this.lastNativeMarkReadRequestOutcome = outcome.success === true ? 'committed' : 'failed';
            this.lastNativeMarkReadRequestErrorCode = outcome.errorCode ?? '';
        }
        const presented = outcome.success === true && outcome.stale !== true
            && this.#isMarkReadPresentationCurrent(presentation)
            && this.#applyCommittedMarkReadPayload(validatedPayload, outcome.nativeResult, reason, animateStateID);
        return {
            success: outcome.success === true,
            permitsAutoAdvance: presented && outcome.nativeResult?.isMarked === true
                && outcome.nativeResult?.permitsAutoAdvance === true,
            presentation: presented ? presentation : null,
        };
    }
    applyMarkSectionAsReadResult(result) {
        return this.nativeMarkReadRequestCoordinator?.settle?.(result) ?? false;
    }
    buildMarkAllSectionsAsReadPayload() {
        const doc = getPrimaryRendererContent(this.view?.renderer)?.doc;
            sentenceIdentifiers: payloadSentenceIdentifiers,
        };
    }
    applyCommittedMarkAllSectionsAsReadPayload(payload, nativeResult) {
        const applied = this.#applyCommittedMarkReadPayload(
            payload, nativeResult, 'native-mark-all-read-committed'
        );
        return applied ? (payload.segments.length || payload.sentenceIdentifiers.length) : 0;
    }
    // Retained only for older diagnostics. Optimistic publication is prohibited.
    applyOptimisticMarkAllSectionsAsReadPayload(_payload) {
        return 0;
    }
    async markAllSectionsAsRead() {
        const payload = this.buildMarkAllSectionsAsReadPayload();
        const doc = getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
        if (!payload || !isDocumentLike(doc)) {
            return 0;
        }
        const outcome = await this.#submitMarkReadPayload(payload, {
            sectionID: `ebook-mark-all:${this.#lifecycleGeneration}`,
            owner: this.#markReadOwner({ document: doc }),
            reason: 'native-mark-all-read-committed',
        });
        return outcome.success
            ? (payload.segments.length || payload.sentenceIdentifiers.length)
            : 0;
    }
    async #markPageClusterAsRead(stateID) {
        const pageTrackingState = this.pageTrackingStates.find((state) => state.id === stateID);
        if (!pageTrackingState) {
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
        this.lastNativeMarkReadRequestOutcome = 'pending';
        this.pageTrackingBusyStateIDs.add(stateID);
        this.#renderPageTrackingButtons('mark-read-busy');
        try {
            const outcome = await this.#submitMarkReadPayload(pageTrackingState.payload, {
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
        } finally {
            this.pageTrackingBusyStateIDs.delete(stateID);
            this.#renderPageTrackingButtons('mark-read-finished');
        }
    }
    async markVisiblePageAsRead(source = 'native') {
        const completionAction = this.completionAction;
        if (completionAction) {
            if (this.completionActionBusy) {
                return false;
            }
        this.initialPaginatorSettleHandle = requestAnimationFrame(async () => {
            this.initialPaginatorSettleHandle = null;
            if (this.#closed) return;
            await this.#settleInitialPaginatorLayout(reason);
        });
    }
    async #advanceAfterMarkRead(owner) {
        await new Promise((resolve) => setTimeout(resolve, 430));
        if (
            !owner
            || owner.permitsAutoAdvance !== true
            || !this.#isMarkReadPresentationCurrent(owner.presentation)
            || !this.#isRendererLifecycleCurrent(owner.lifecycleGeneration, owner.renderer)
            || this.visiblePageCollectionGeneration !== owner.visiblePageCollectionGeneration
        ) {
            return false;
        }
        if (this.isRTL) {
            return await this.view?.goLeft?.() === true;
        } else {
            return await this.view?.goRight?.() === true;
        }
    }
    #releaseSideNavChevronHoverSuppression(key) {
        const cleanup = this.#chevronHoverSuppressionCleanup[key];
        this.#chevronHoverSuppressionCleanup[key] = null;
        cleanup?.();
    }
