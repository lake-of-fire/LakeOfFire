        this.#bindGlobal(window, 'manabi_markVisiblePageAsRead', async (source = 'native') => {
            return await this.markVisiblePageAsRead(source);
        });
        this.#listen(window, 'resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
        this.#listen(window.visualViewport, 'resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
    applyBookReadingProgress(articleReadingProgress, _reason = 'unspecified') {
        const incomingProgress = normalizeArticleReadingProgress(articleReadingProgress);
        const incomingReadSegmentIdentifiers = new Set(incomingProgress.readSegmentIdentifiers);
        const incomingSentenceIdentifiersRead = new Set(incomingProgress.sentenceIdentifiersRead);
        for (const segmentIdentifier of this.optimisticReadSegmentIdentifiers) {
            incomingReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of this.optimisticSentenceIdentifiersRead) {
            incomingSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        incomingProgress.readSegmentIdentifiers = Array.from(incomingReadSegmentIdentifiers);
        incomingProgress.sentenceIdentifiersRead = Array.from(incomingSentenceIdentifiersRead);
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
    #applyCommittedMarkReadPayload(payload, reason, animateStateID = null) {
        const validatedPayload = this.#validatedMarkReadPayload(payload);
        if (!validatedPayload) return 0;
        const payloadSegmentIdentifiers = validatedPayload.segments
            .map(segment => segment.stableSegmentID);
        for (const segmentIdentifier of payloadSegmentIdentifiers) {
            this.optimisticReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of validatedPayload.sentenceIdentifiers) {
            this.optimisticSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        if (animateStateID) {
            this.pageTrackingAnimateReadStateIDs.add(animateStateID);
        }
        const committedProgress = normalizeArticleReadingProgress(this.articleReadingProgress);
        committedProgress.readSegmentIdentifiers = Array.from(new Set([
            ...committedProgress.readSegmentIdentifiers,
            ...payloadSegmentIdentifiers,
        ]));
        committedProgress.sentenceIdentifiersRead = Array.from(new Set([
            ...committedProgress.sentenceIdentifiersRead,
            ...validatedPayload.sentenceIdentifiers,
        ]));
        this.applyBookReadingProgress(committedProgress, reason);
        return validatedPayload.segments.length;
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
            return false;
        }
        const outcome = await this.nativeMarkReadRequestCoordinator.request({
            sectionID,
            owner,
            context: {
                payload: validatedPayload,
                reason,
                animateStateID,
            },
            message: {
                ...validatedPayload,
                topWindowURL: window.top.location.href,
                pageURL: owner?.document?.location?.href ?? null,
                documentStartedAtMs: Number.isFinite(window.top?.performance?.timeOrigin)
                    ? window.top.performance.timeOrigin
                    : readerDocumentStartedAtMs(),
            },
        });
        this.lastNativeMarkReadRequestOutcome = outcome.success === true
            ? 'committed'
            : 'failed';
        this.lastNativeMarkReadRequestErrorCode = outcome.errorCode ?? '';
        if (outcome.success !== true) return false;
        this.#applyCommittedMarkReadPayload(
            outcome.context.payload,
            outcome.context.reason,
            outcome.context.animateStateID
        );
        return true;
    }
    applyMarkSectionAsReadResult(result) {
        return this.nativeMarkReadRequestCoordinator?.settle?.(result) ?? false;
    }
    buildMarkAllSectionsAsReadPayload() {
        const doc = getPrimaryRendererContent(this.view?.renderer)?.doc;
            sentenceIdentifiers: payloadSentenceIdentifiers,
        };
    }
    applyCommittedMarkAllSectionsAsReadPayload(payload) {
        return this.#applyCommittedMarkReadPayload(
            payload,
            'native-mark-all-read-committed'
        );
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
        const success = await this.#submitMarkReadPayload(payload, {
            sectionID: `ebook-mark-all:${this.#lifecycleGeneration}`,
            owner: this.#markReadOwner({ document: doc }),
            reason: 'native-mark-all-read-committed',
        });
        return success
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
            const success = await this.#submitMarkReadPayload(pageTrackingState.payload, {
                sectionID: `ebook-page:${stateID}:${this.visiblePageCollectionGeneration}`,
                owner: this.#markReadOwner({
                    document: doc,
                    requireVisibleGeneration: true,
                }),
                reason: 'native-mark-read-committed',
                animateStateID: stateID,
            });
            if (!success) return false;
            await this.#advanceAfterMarkRead(advanceOwner);
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
