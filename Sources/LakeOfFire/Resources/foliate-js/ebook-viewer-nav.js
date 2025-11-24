const MAX_RELOCATE_STACK = 50;
const FRACTION_EPSILON = 0.000001;

const flattenPageTargets = (items, collector = []) => {
    if (!Array.isArray(items)) return collector;
    for (const item of items) {
        if (!item) continue;
        collector.push(item);
        if (Array.isArray(item.subitems) && item.subitems.length) {
            flattenPageTargets(item.subitems, collector);
        }
    }
    return collector;
};

const ensurePageKey = (item, fallbackIndex = 0) => {
    if (!item) return null;
    if (item.__manabiPageKey) return item.__manabiPageKey;
    const key = item.href ?? `${item.label ?? 'page'}-${fallbackIndex}`;
    try {
        Object.defineProperty(item, '__manabiPageKey', {
            value: key,
            enumerable: false,
            configurable: false,
            writable: false,
        });
    } catch (error) {
        // ignore inability to define property
    }
    return key;
};

export class NavigationHUD {
    constructor({ onJumpRequest, getRenderer, formatPercent } = {}) {
        this.onJumpRequest = onJumpRequest;
        this.getRenderer = getRenderer;
        this.formatPercent = formatPercent ?? (value => `${Math.round(value * 100)}%`);
        
        this.navBar = document.getElementById('nav-bar');
        this.navPrimaryText = document.getElementById('nav-primary-text');
        this.navPrimaryTextFull = document.getElementById('nav-primary-text-full');
        this.navPrimaryTextCompact = document.getElementById('nav-primary-text-compact');
        this.navSectionProgress = {
            leading: document.getElementById('nav-section-progress-leading'),
            trailing: document.getElementById('nav-section-progress-trailing'),
        };
        this.navRelocateButtons = {
            back: document.getElementById('nav-relocate-back'),
            forward: document.getElementById('nav-relocate-forward'),
        };
        this.navRelocateLabels = {
            back: document.getElementById('nav-relocate-label-back'),
            forward: document.getElementById('nav-relocate-label-forward'),
        };
        this.completionStack = document.getElementById('completion-stack');
        this.progressWrapper = document.getElementById('progress-wrapper');
        this.progressSlider = document.getElementById('progress-slider');
        
        this.hideNavigationDueToScroll = false;
        this.isRTL = false;
        this.navContext = null;
        this.totalPageCount = 0;
        this.pageTargets = [];
        this.pageTargetIndexByKey = new Map();
        this.currentLocationDescriptor = null;
        this.lastRelocateDetail = null;
        this.isProcessingRelocateJump = false;
        this.relocateStacks = {
            back: [],
            forward: [],
        };
        this.scrubSession = null;
        this.pendingRelocateJump = null;
        this.primaryLineRequestToken = 0;
        this.rendererPageSnapshot = null;
        this.latestPrimaryLabel = '';
        this.previousRelocateVisibility = {
            back: null,
            forward: null,
        };
        this.lastPrimaryLabelDiagnostics = null;
        this.fallbackTotalPageCount = null;
        this.lastTotalSource = null;
        if (this.pendingScrubCommit) {
            this.#logPageScrub('pending-commit-reset', {
                reason: 'new-scrub',
            });
            this.pendingScrubCommit = null;
        }

        this.navRelocateButtons.back?.addEventListener('click', () => this.#handleRelocateJump('back'));
        this.navRelocateButtons.forward?.addEventListener('click', () => this.#handleRelocateJump('forward'));
        this.#updateRelocateButtons();
        this.#applyRelocateButtonEdges();
    }

    #logJumpBack(event, payload = {}) {
        const cleanedEntries = Object.entries(payload ?? {}).filter(([, value]) => value !== undefined);
        const metadata = cleanedEntries.length ? JSON.stringify(Object.fromEntries(cleanedEntries)) : '';
        const line = metadata ? `# JUMPBACK ${event} ${metadata}` : `# JUMPBACK ${event}`;
        try {
            window.webkit?.messageHandlers?.print?.postMessage?.(line);
        } catch (_error) {
            // optional native logger
        }
        try {
            console.log(line);
        } catch (_error) {
            // optional console logger
        }
    }

    setIsRTL(isRTL) {
        this.isRTL = !!isRTL;
        this.#applyRelocateButtonEdges();
        this.#updateSectionProgress();
    }
    
    setPageTargets(pageList) {
        this.pageTargets = flattenPageTargets(pageList ?? []);
        this.pageTargetIndexByKey = new Map();
        this.pageTargets.forEach((item, index) => {
            const key = ensurePageKey(item, index);
            if (key) {
                this.pageTargetIndexByKey.set(key, index);
            }
        });
        this.totalPageCount = this.pageTargets.length;
        if (this.totalPageCount > 0) {
            this.fallbackTotalPageCount = this.totalPageCount;
        }
        this.#logPageNumberDiagnostic('set-page-targets', {
            pageTargetCount: this.totalPageCount,
        });
        if (this.lastRelocateDetail) {
            this.#updatePrimaryLine(this.lastRelocateDetail);
        }
    }
    
    setNavContext(context) {
        this.navContext = context ?? null;
        this.#toggleCompletionStack();
        this.#updateSectionProgress();
        this.#updateRelocateButtons();
    }
    
    setHideNavigationDueToScroll(shouldHide) {
        this.hideNavigationDueToScroll = !!shouldHide;
        this.navBar?.classList.toggle('nav-hidden-due-to-scroll', this.hideNavigationDueToScroll);
        if (this.progressWrapper) {
            this.progressWrapper.setAttribute('aria-hidden', this.hideNavigationDueToScroll ? 'true' : 'false');
        }
        if (this.progressSlider) {
            if (this.hideNavigationDueToScroll) {
                this.progressSlider.setAttribute('tabindex', '-1');
            } else {
                this.progressSlider.removeAttribute('tabindex');
            }
        }
        if (this.lastRelocateDetail) {
            this.#updatePrimaryLine(this.lastRelocateDetail);
        }
        this.#updateRelocateButtons();
    }

    getCurrentDescriptor() {
        return this.#cloneDescriptor(this.currentLocationDescriptor);
    }

    beginProgressScrubSession(originDescriptor) {
        if (this.pendingScrubCommit) {
            const fallbackDescriptor = this.#cloneDescriptor(this.currentLocationDescriptor);
            if (fallbackDescriptor) {
                const flushed = this.#maybeCommitPendingScrub({
                    reason: 'scrub-begin-flush',
                    liveScrollPhase: 'settled',
                }, fallbackDescriptor);
                if (!flushed && this.pendingScrubCommit) {
                    this.#logPageScrub('pending-commit-awaiting-detail', {
                        reason: 'scrub-begin',
                        pendingOriginFraction: typeof this.pendingScrubCommit?.origin?.fraction === 'number'
                            ? Number(this.pendingScrubCommit.origin.fraction.toFixed(6))
                            : null,
                    });
                }
            } else if (this.pendingScrubCommit) {
                this.#logPageScrub('pending-commit-awaiting-detail', {
                    reason: 'scrub-begin-no-descriptor',
                });
            }
        }
        const baselineDescriptor = this.#cloneDescriptor(originDescriptor)
            || this.#cloneDescriptor(this.currentLocationDescriptor)
            || null;
        const originFraction = typeof baselineDescriptor?.fraction === 'number'
            ? baselineDescriptor.fraction
            : null;
        const frozenLabel = this.getPrimaryDisplayLabel(baselineDescriptor)
            || this.navPrimaryText?.textContent
            || this.latestPrimaryLabel
            || '';
        this.scrubSession = {
            active: true,
            originDescriptor: baselineDescriptor,
            originFraction,
            hasMoved: false,
            frozenLabel,
        };
        if (frozenLabel && this.navPrimaryText) {
            const fullLabelTarget = this.navPrimaryTextFull ?? this.navPrimaryText;
            const compactLabelTarget = this.navPrimaryTextCompact ?? this.navPrimaryText;
            fullLabelTarget.textContent = frozenLabel;
            compactLabelTarget.textContent = frozenLabel;
        }
        this.#logPageScrub('begin', {
            originFraction,
            hasDescriptor: !!baselineDescriptor,
        });
        this.#logJumpDiagnostic('scrub-begin', {
            hasOrigin: !!originDescriptor,
            backDepth: this.relocateStacks.back.length,
        });
        this.#updateRelocateButtons();
    }

    endProgressScrubSession(finalDescriptor, { cancel, releaseFraction } = {}) {
        if (!this.scrubSession) return;
        const session = this.scrubSession;
        const comparisonDescriptor = this.#cloneDescriptor(finalDescriptor ?? this.currentLocationDescriptor);
        let committed = false;
        let returnedToOrigin = false;
        let deferredCommit = false;
        const releaseValue = typeof releaseFraction === 'number' ? releaseFraction : (comparisonDescriptor?.fraction ?? null);
        const releaseMoved = typeof releaseValue === 'number'
            && typeof session.originFraction === 'number'
            && Math.abs(releaseValue - session.originFraction) > FRACTION_EPSILON;
        if (!cancel && session.originDescriptor && session.hasMoved && releaseMoved) {
            this.pendingScrubCommit = {
                origin: this.#cloneDescriptor(session.originDescriptor),
                reason: 'scrub-release',
                releaseFraction: releaseValue,
                scheduledAt: Date.now(),
                releaseDescriptor: comparisonDescriptor,
            };
            deferredCommit = true;
            this.#logPageScrub('pending-commit', {
                originFraction: session.originFraction ?? null,
                releaseFraction: releaseValue,
            });
        } else {
            this.pendingScrubCommit = null;
            if (!cancel) {
                returnedToOrigin = !session.hasMoved || !releaseMoved;
            }
        }
        const releaseDescriptor = this.#descriptorFromFraction(releaseValue) || comparisonDescriptor;
        if (this.pendingScrubCommit && releaseDescriptor) {
            const pushedNow = this.#maybeCommitPendingScrub({
                reason: 'scrub-finalize',
                liveScrollPhase: 'settled',
            }, releaseDescriptor, { updateButtons: false });
            if (pushedNow) {
                committed = true;
                deferredCommit = false;
                this.#updateRelocateButtons();
            } else {
                deferredCommit = !!this.pendingScrubCommit;
            }
        } else {
            deferredCommit = !!this.pendingScrubCommit;
        }
        this.#logPageScrub('end', {
            cancel,
            committed,
            returnedToOrigin,
            deferredCommit,
        });
        this.scrubSession = null;
        this.#updateRelocateButtons();
        if (comparisonDescriptor || this.currentLocationDescriptor) {
            this.#updatePrimaryLine(comparisonDescriptor || this.currentLocationDescriptor);
        }
        this.#logJumpDiagnostic('scrub-end', {
            cancel,
            committed,
            returnedToOrigin,
            hadMovement: session.hasMoved,
            originFraction: session.originFraction ?? null,
            finalFraction: comparisonDescriptor?.fraction ?? null,
            backDepth: this.relocateStacks.back.length,
            forwardDepth: this.relocateStacks.forward.length,
        });
    }
    
    async handleRelocate(detail) {
        if (!detail) return;
        await this.#refreshRendererSnapshot();
        this.lastRelocateDetail = detail;
        this.#handleRelocateHistory(detail);
        this.#logJumpBack('relocate-detail', {
            reason: detail?.reason ?? null,
            phase: detail?.liveScrollPhase ?? null,
            fraction: typeof detail?.fraction === 'number' ? Number(detail.fraction.toFixed(6)) : null,
            processingPending: this.isProcessingRelocateJump,
        });
        this.#logRelocateDetail(detail);
        this.#updatePrimaryLine(detail);
        this.#toggleCompletionStack();
        await this.#updateSectionProgress({ refreshSnapshot: false });
        this.#updateRelocateButtons();
        this.#pruneBackStackIfReturnedToOrigin(detail);
        this.#logPageNumberDiagnostic('relocate', {
            reason: detail?.reason ?? null,
            liveScrollPhase: detail?.liveScrollPhase ?? null,
            fraction: typeof detail?.fraction === 'number' ? detail.fraction : null,
            label: this.latestPrimaryLabel ?? '',
            ...(this.lastPrimaryLabelDiagnostics ?? {}),
        });
    }
    
    #updatePrimaryLine(detail) {
        const fullLabelTarget = this.navPrimaryTextFull ?? this.navPrimaryText;
        const compactLabelTarget = this.navPrimaryTextCompact ?? this.navPrimaryText;
        if (!fullLabelTarget || !compactLabelTarget) return;

        if (this.scrubSession?.active && this.scrubSession.frozenLabel != null) {
            fullLabelTarget.textContent = this.scrubSession.frozenLabel;
            compactLabelTarget.textContent = this.scrubSession.frozenLabel;
            return;
        }

        const fullLabel = this.formatPrimaryLabel(detail);
        const compactLabel = this.formatPrimaryLabel(detail, { allowRendererFallback: true, condensedOnly: true });

        if (fullLabel) {
            fullLabelTarget.textContent = fullLabel;
            this.latestPrimaryLabel = fullLabel;
        } else {
            fullLabelTarget.textContent = '';
            this.#requestRendererPrimaryLine();
        }

        if (compactLabel) {
            compactLabelTarget.textContent = compactLabel;
        } else {
            compactLabelTarget.textContent = fullLabelTarget.textContent;
        }
    }

    #applyRelocateButtonEdges() {
        const backEdge = this.isRTL ? 'right' : 'left';
        const forwardEdge = this.isRTL ? 'left' : 'right';
        this.#setButtonEdge(this.navRelocateButtons?.back, backEdge);
        this.#setButtonEdge(this.navRelocateButtons?.forward, forwardEdge);
    }

    #setButtonEdge(button, edge) {
        if (!button || (edge !== 'left' && edge !== 'right')) return;
        if (button.dataset.navEdge !== edge) {
            button.dataset.navEdge = edge;
        }
        const icon = button.querySelector('.nav-relocate-icon');
        const label = button.querySelector('.nav-relocate-page');
        if (!icon || !label) return;
        if (edge === 'left') {
            if (icon.nextElementSibling !== label) {
                button.insertBefore(icon, label);
            }
        } else {
            if (label.nextElementSibling !== icon) {
                button.insertBefore(label, icon);
            }
        }
    }

    #descriptorForRelocateLabel(direction) {
        const stack = this.relocateStacks?.[direction];
        if (stack?.length) {
            return stack[stack.length - 1];
        }
        if (direction === 'back' && this.scrubSession?.active && this.scrubSession.originDescriptor) {
            return this.scrubSession.originDescriptor;
        }
        return null;
    }

    formatPrimaryLabel(detail, { allowRendererFallback = true, condensedOnly = false } = {}) {
        const derived = this.#derivePrimaryLabel(detail);
        if (derived) {
            const label = condensedOnly ? this.#condensePrimaryLabel(derived) : derived;
            if (!condensedOnly) {
                this.latestPrimaryLabel = label;
            }
            return label;
        }
        if (allowRendererFallback && this.rendererPageSnapshot) {
            const fallback = this.#formatRendererPageLabel(this.rendererPageSnapshot);
            if (fallback) {
                const label = condensedOnly ? this.#condensePrimaryLabel(fallback) : fallback;
                if (!condensedOnly) {
                    this.latestPrimaryLabel = label;
                }
                return label;
            }
        }
        return '';
    }

    getPrimaryDisplayLabel(detail) {
        const label = this.formatPrimaryLabel(detail, { allowRendererFallback: true });
        if (label) return label;
        return this.navPrimaryText?.textContent || this.latestPrimaryLabel || '';
    }

    getPageEstimate(detail) {
        const metrics = this.#computePageMetrics(detail);
        if (!metrics) return null;
        return {
            current: metrics.currentPageNumber ?? null,
            total: metrics.totalPages ?? null,
        };
    }

    #derivePrimaryLabel(detail) {
        if (!detail) {
            this.lastPrimaryLabelDiagnostics = {
                source: 'no-detail',
                label: '',
                totalPageCount: this.totalPageCount,
            };
            return '';
        }
        const metrics = this.#computePageMetrics(detail);
        if (!metrics) {
            this.lastPrimaryLabelDiagnostics = {
                source: 'pending-renderer',
                label: '',
                totalPageCount: this.totalPageCount,
            };
            return '';
        }
        const { currentPageNumber, totalPages, pageItemLabel, diag } = metrics;
        const commit = (label, source) => {
            this.lastPrimaryLabelDiagnostics = {
                ...diag,
                label: label ?? '',
                source,
            };
            return label ?? '';
        };
        if (this.hideNavigationDueToScroll && currentPageNumber != null) {
            return commit(String(currentPageNumber), 'hide-nav-current');
        }
        if (typeof totalPages === 'number' && totalPages > 0 && currentPageNumber != null) {
            const source = diag.pageIndexFromItem != null ? 'page-target-index'
                : (diag.locationCurrent != null ? 'location-estimate' : 'fraction-estimate');
            return commit(`${currentPageNumber} of ${totalPages}`, source);
        }
        if (currentPageNumber != null) {
            const source = diag.pageIndexFromItem != null ? 'page-target-index-no-total'
                : (diag.locationCurrent != null ? 'location-no-total' : 'fraction-no-total');
            return commit(String(currentPageNumber), source);
        }
        if (pageItemLabel) {
            return commit(this.#sanitizePageLabel(pageItemLabel), 'page-item-label');
        }
        this.lastPrimaryLabelDiagnostics = {
            ...diag,
            label: '',
            source: 'pending-renderer',
        };
        return '';
    }

    #condensePrimaryLabel(label) {
        if (typeof label !== 'string') return '';
        // If label is already condensed (single number) return as-is
        if (!label.includes(' of ')) return label;
        const [current, total] = label.split(' of ');
        const trimmedCurrent = current?.trim() ?? '';
        if (!trimmedCurrent) return label;
        return trimmedCurrent;
    }

    #computePageMetrics(detail) {
        if (!detail) return null;
        const fraction = typeof detail.fraction === 'number' ? detail.fraction : null;
        const pageItem = detail.pageItem ?? null;
        const pageItemLabel = typeof pageItem?.label === 'string' ? pageItem.label : null;
        const pageItemKey = pageItem ? ensurePageKey(pageItem) : null;
        const pageIndex = this.#resolvePageIndex(pageItem);
        const locationCurrent = typeof detail.location?.current === 'number' ? detail.location.current : null;
        const locationTotal = typeof detail.location?.total === 'number' ? detail.location.total : null;
        const totalPages = this.#currentTotalPages(detail);
        const approxIndexFromFraction = this.#pageIndexFromFraction(fraction, totalPages);
        const locationIndex = locationCurrent != null ? locationCurrent : null;
        const rendererIndex = this.#rendererSnapshotIndex();
        const candidateIndex = [pageIndex, approxIndexFromFraction, locationIndex, rendererIndex]
            .find(index => typeof index === 'number' && index >= 0);
        const currentPageNumber = candidateIndex != null ? candidateIndex + 1 : null;
        const diag = {
            fraction,
            pageItemKey,
            pageItemLabel,
            pageIndexFromItem: pageIndex,
            approxIndexFromFraction,
            locationCurrent,
            locationTotal,
            candidateIndex,
            totalPageCount: this.totalPageCount,
            fallbackTotalPageCount: this.fallbackTotalPageCount,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            rendererSnapshotCurrent: this.rendererPageSnapshot?.current ?? null,
            rendererSnapshotTotal: this.rendererPageSnapshot?.total ?? null,
            effectiveTotalPages: totalPages ?? null,
            totalSource: this.lastTotalSource ?? null,
        };
        return {
            currentPageNumber,
            totalPages,
            pageItemLabel,
            diag,
        };
    }
    
    #toggleCompletionStack(forceShow) {
        const shouldShow = typeof forceShow === 'boolean'
            ? forceShow
            : !!(this.navContext?.showingFinish || this.navContext?.showingRestart);
        if (this.completionStack) {
            this.completionStack.hidden = !shouldShow;
            this.completionStack.style.display = shouldShow ? '' : 'none';
        }
        const fadeTargets = [
            this.navRelocateButtons?.back,
            this.navRelocateButtons?.forward,
            this.navSectionLabels?.leading,
            this.navSectionLabels?.trailing,
            this.navPrimaryText,
        ].filter(Boolean);
        fadeTargets.forEach(el => {
            if (shouldShow) {
                el.classList.add('nav-fade-out');
            } else {
                el.classList.remove('nav-fade-out');
            }
        });
        if (this.navPrimaryText) {
            this.navPrimaryText.hidden = shouldShow;
            if (shouldShow) {
                this.navPrimaryText.setAttribute('aria-hidden', 'true');
            } else {
                this.navPrimaryText.removeAttribute('aria-hidden');
            }
        }
    }

    async #updateSectionProgress({ refreshSnapshot = true } = {}) {
        const leading = this.navSectionProgress?.leading;
        const trailing = this.navSectionProgress?.trailing;
        if (leading) leading.hidden = true;
        if (trailing) trailing.hidden = true;
        try {
            const pagesLeft = await this.#calculatePagesLeftInSection({ refreshSnapshot });
            const showingCompletion = this.navContext?.showingFinish || this.navContext?.showingRestart;
            if (this.hideNavigationDueToScroll || showingCompletion) return;
            const targetKey = this.isRTL ? 'leading' : 'trailing';
            const labelEdge = targetKey === 'leading' ? 'left' : 'right';
            const forwardEdge = this.isRTL ? 'left' : 'right';
            const relocateDirection = labelEdge === forwardEdge ? 'forward' : 'back';
            if (this.#isRelocateButtonVisible(relocateDirection)) return;
            if (!pagesLeft || pagesLeft <= 0) return;
            const target = this.navSectionProgress?.[targetKey];
            if (!target) return;
            const label = pagesLeft === 1
                ? '1 page left in chapter'
                : `${pagesLeft} pages left in chapter`;
            target.textContent = label;
            target.hidden = false;
        } catch (error) {
            console.error('Failed to update section progress', error);
        }
    }

    
    async #calculatePagesLeftInSection({ refreshSnapshot = true } = {}) {
        if (refreshSnapshot) {
            await this.#refreshRendererSnapshot();
        }
        if (!this.rendererPageSnapshot || !this.rendererPageSnapshot.total || this.rendererPageSnapshot.total <= 0) return null;
        return Math.max(0, this.rendererPageSnapshot.total - this.rendererPageSnapshot.current);
    }
    
    #handleRelocateHistory(detail) {
        const descriptor = this.#makeLocationDescriptor(detail);
        if (!descriptor) return;
        if (this.isProcessingRelocateJump) {
            this.currentLocationDescriptor = descriptor;
            this.#finalizePendingRelocateJump(descriptor);
            if (this.isProcessingRelocateJump || this.pendingRelocateJump) {
                this.#logJumpBack('relocate-finalize-pending', {
                    pending: !!this.pendingRelocateJump,
                    descriptorFraction: typeof descriptor?.fraction === 'number' ? Number(descriptor.fraction.toFixed(6)) : null,
                });
                return;
            }
            // fall through to normal handling to capture subsequent movement if needed
        }
        const reason = (detail?.reason || '').toLowerCase();
        const liveScrollPhase = detail?.liveScrollPhase ?? null;
        const isLiveScrollReason = reason === 'live-scroll';
        const isJumpReason = isLiveScrollReason || reason === 'navigation';
        const previousDescriptor = this.currentLocationDescriptor;
        let descriptorChanged = previousDescriptor && !this.#isSameDescriptor(previousDescriptor, descriptor);
        const isScrubbing = !!this.scrubSession?.active;
        const originDescriptor = this.scrubSession?.originDescriptor;
        const originFraction = typeof this.scrubSession?.originFraction === 'number' ? this.scrubSession.originFraction : null;
        const detailFraction = typeof detail?.fraction === 'number' ? detail.fraction : null;
        const fractionMoved = originFraction != null && detailFraction != null && Math.abs(detailFraction - originFraction) > FRACTION_EPSILON;
        const descriptorDiffersFromOrigin = !!(isScrubbing && originDescriptor && descriptor && !this.#isSameDescriptor(originDescriptor, descriptor));
        const movedFromOrigin = isScrubbing && (fractionMoved || descriptorDiffersFromOrigin);
        if (!descriptorChanged && movedFromOrigin && previousDescriptor && descriptor) {
            descriptorChanged = true;
        }
        if (isScrubbing) {
            this.#trackScrubMovement({ descriptor, movedFromOrigin, detailFraction });
        }
        if (isJumpReason && descriptorChanged && !isLiveScrollReason) {
            if (!isScrubbing && previousDescriptor) {
                this.#pushBackStack(previousDescriptor);
            }
        } else if (!isScrubbing && descriptorChanged) {
            this.relocateStacks.forward.length = 0;
            this.#logStackSnapshot('forward-clear');
        }
        this.#logJumpDiagnostic('relocate-history', {
            reason,
            isJumpReason,
            descriptorChanged,
            backDepth: this.relocateStacks.back.length,
            forwardDepth: this.relocateStacks.forward.length,
            scrubbing: isScrubbing,
            movedFromOrigin,
            hiddenDueToScroll: this.hideNavigationDueToScroll,
            liveScrollPhase,
        });
        this.currentLocationDescriptor = descriptor;
        this.#maybeCommitPendingScrub(detail, descriptor);
    }

    #trackScrubMovement({ descriptor, movedFromOrigin, detailFraction }) {
        const session = this.scrubSession;
        if (!session || !session.active) return;
        if (!session.originDescriptor && descriptor) {
            session.originDescriptor = this.#cloneDescriptor(descriptor);
            if (session.originFraction == null && typeof descriptor?.fraction === 'number') {
                session.originFraction = descriptor.fraction;
            }
        }
        const fractionFromDescriptor = typeof descriptor?.fraction === 'number' ? descriptor.fraction : null;
        const previewFraction = fractionFromDescriptor ?? detailFraction ?? null;
        if (movedFromOrigin) {
            session.hasMoved = true;
            this.#logPageScrub('update', {
                fraction: previewFraction,
                originFraction: session.originFraction ?? null,
                movedFromOrigin,
            });
        }
    }

    #pushBackStack(descriptor, { stripCFI = false } = {}) {
        if (!descriptor) return null;
        const entry = this.#cloneDescriptor(descriptor);
        if (!entry) return null;
        if (stripCFI) {
            entry.cfi = null;
        }
        const backStack = this.relocateStacks.back;
        backStack.push(entry);
        const index = backStack.length - 1;
        if (backStack.length > MAX_RELOCATE_STACK) {
            backStack.shift();
            this.#logPageScrub('pop', { index: 0, reason: 'truncate' });
        }
        this.relocateStacks.forward.length = 0;
        this.#logPageScrub('stack', {
            action: 'push',
            index,
            fraction: entry.fraction ?? null,
        });
        this.#logJumpDiagnostic('relocate-stack-push', {
            backDepth: backStack.length,
            forwardDepth: this.relocateStacks.forward.length,
            hiddenDueToScroll: this.hideNavigationDueToScroll,
        });
        this.#logStackSnapshot('push');
        return { entry, index };
    }
    
    #makeLocationDescriptor(detail) {
        if (!detail) return null;
        return {
            cfi: detail.cfi ?? null,
            fraction: typeof detail.fraction === 'number' ? detail.fraction : null,
            pageItemKey: detail.pageItem ? ensurePageKey(detail.pageItem) : null,
            pageLabel: typeof detail.pageItem?.label === 'string' ? detail.pageItem.label : null,
        };
    }

    #descriptorFromFraction(fraction) {
        if (typeof fraction !== 'number' || !isFinite(fraction)) return null;
        return {
            cfi: null,
            fraction,
            pageItemKey: null,
            pageLabel: null,
        };
    }

    #cloneDescriptor(descriptor) {
        if (!descriptor) return null;
        return {
            cfi: descriptor.cfi ?? null,
            fraction: typeof descriptor.fraction === 'number' ? descriptor.fraction : null,
            pageItemKey: descriptor.pageItemKey ?? null,
            pageLabel: descriptor.pageLabel ?? null,
        };
    }
    
    #requestRendererPrimaryLine() {
        const renderer = this.getRenderer?.();
        if (!renderer || typeof renderer.page !== 'function' || typeof renderer.pages !== 'function') {
            return;
        }
        const token = ++this.primaryLineRequestToken;
        Promise.allSettled([renderer.page(), renderer.pages()]).then(results => {
            if (token !== this.primaryLineRequestToken) return;
            const [pageResult, pagesResult] = results;
            if (pageResult.status !== 'fulfilled' || pagesResult.status !== 'fulfilled') {
                return;
            }
            const normalized = this.#normalizeRendererPageInfo(pageResult.value, pagesResult.value);
            if (!normalized) {
                return;
            }
            this.rendererPageSnapshot = normalized;
            const label = this.#formatRendererPageLabel(normalized);
            if (label) {
                const fullLabelTarget = this.navPrimaryTextFull ?? this.navPrimaryText;
                const compactLabelTarget = this.navPrimaryTextCompact ?? this.navPrimaryText;
                fullLabelTarget.textContent = label;
                compactLabelTarget.textContent = this.#condensePrimaryLabel(label) || label;
                this.latestPrimaryLabel = label;
                this.lastPrimaryLabelDiagnostics = {
                    label,
                    source: 'renderer-primary-line',
                    rendererSnapshotCurrent: normalized.current,
                    rendererSnapshotTotal: normalized.total,
                    totalPageCount: this.totalPageCount,
                };
                this.#logPageNumberDiagnostic('renderer-primary-line', this.lastPrimaryLabelDiagnostics);
            }
        }).catch(() => {});
    }
    
    #normalizeRendererPageInfo(rawPage, rawTotal, renderer) {
        if (rawPage == null && rawTotal == null) return null;
        const numericPage = Number(rawPage);
        const numericTotal = Number(rawTotal);
        let total = Number.isFinite(numericTotal) ? Math.max(1, Math.round(numericTotal)) : null;
        const currentBase = Number.isFinite(numericPage) ? Math.max(1, Math.round(numericPage)) : 1;
        const current = total ? Math.max(1, Math.min(total, currentBase)) : currentBase;
        if (!Number.isFinite(current)) return null;
        // Foliate paginator inserts two sentinel “pages” (lead/trail). Adjust so UI shows text pages only.
        const isPaginated = renderer && renderer.scrolled === false;
        if (isPaginated && total && total > 2) {
            const textTotal = Math.max(1, total - 2);
            const textCurrent = Math.max(1, Math.min(textTotal, current - 1));
            return {
                current: textCurrent,
                total: textTotal,
                rawCurrent: current,
                rawTotal: total,
            };
        }
        return {
            current,
            total,
            rawCurrent: current,
            rawTotal: total,
        };
    }
    
    #formatRendererPageLabel(info) {
        if (!info) return '';
        if (info.total && info.total > 0) {
            return `${info.current} of ${info.total}`;
        }
        return '';
    }

    async #refreshRendererSnapshot() {
        const renderer = this.getRenderer?.();
        if (!renderer || typeof renderer.page !== 'function' || typeof renderer.pages !== 'function') {
            return null;
        }
        try {
            const [pageResult, pagesResult] = await Promise.allSettled([renderer.page(), renderer.pages()]);
            if (pageResult.status !== 'fulfilled' || pagesResult.status !== 'fulfilled') {
                return null;
            }
            const normalized = this.#normalizeRendererPageInfo(pageResult.value, pagesResult.value, renderer);
            if (!normalized) return null;
            this.rendererPageSnapshot = normalized;
            this.#updateFallbackTotalPages(normalized.total);
            this.#logPageNumberDiagnostic('renderer-snapshot', {
                rendererCurrent: normalized.current,
                rendererTotal: normalized.total,
                rawRendererCurrent: normalized.rawCurrent,
                rawRendererTotal: normalized.rawTotal,
            });
            return normalized;
        } catch (_error) {
            return null;
        }
    }

    #logPageNumberDiagnostic(event, payload = {}) {
        const base = {
            event,
            totalPageCount: this.totalPageCount,
            totalSource: this.lastTotalSource ?? null,
            ...payload,
        };
        const cleaned = Object.fromEntries(Object.entries(base).filter(([, value]) => value !== undefined));
        const line = `# EBOOKPAGE ${JSON.stringify(cleaned)}`;
        try {
            window.webkit?.messageHandlers?.print?.postMessage?.(line);
        } catch (_error) {
            // optional native logger
        }
        try {
            console.log(line);
        } catch (_error) {
            // optional console logger
        }
    }

    #logPageScrub(_event, _payload = {}) {}

    #logJumpDiagnostic(event, payload = {}) {
        const context = {
            windowURL: this.#safeTopURL(),
            pageURL: document?.location?.href ?? null,
            timestamp: Date.now(),
            ...payload,
        };
        const cleanedEntries = Object.entries(context).filter(([, value]) => value !== undefined && value !== null);
        const metadata = cleanedEntries.length ? JSON.stringify(Object.fromEntries(cleanedEntries)) : '';
        const line = metadata ? `# EBOOKJUMP ${event} ${metadata}` : `# EBOOKJUMP ${event}`;
        try {
            window.webkit?.messageHandlers?.print?.postMessage?.(line);
        } catch (error) {
            // optional handler
        }
        try {
            console.log(line);
        } catch (error) {
            // optional console
        }
    }

    #safeTopURL() {
        try {
            return window.top?.location?.href ?? null;
        } catch (_error) {
            return null;
        }
    }
    
    #isSameDescriptor(a, b) {
        if (!a || !b) return false;
        if (a.cfi && b.cfi) return a.cfi === b.cfi;
        if (typeof a.fraction === 'number' && typeof b.fraction === 'number') {
            return Math.abs(a.fraction - b.fraction) < FRACTION_EPSILON;
        }
        return false;
    }
    
    #resolvePageIndex(pageItem) {
        if (!pageItem || !this.pageTargetIndexByKey) return null;
        const key = ensurePageKey(pageItem);
        if (!key) return null;
        return this.pageTargetIndexByKey.get(key) ?? null;
    }
    
    #pageIndexFromFraction(fraction, totalOverride) {
        const total = typeof totalOverride === 'number' && totalOverride > 0
            ? totalOverride
            : (this.totalPageCount > 0 ? this.totalPageCount : null);
        if (typeof fraction !== 'number' || !total) return null;
        const approx = Math.floor(fraction * total);
        return Math.max(0, Math.min(total - 1, approx));
    }

    #sanitizePageLabel(label) {
        if (typeof label !== 'string') return '';
        const trimmed = label.trim();
        if (!trimmed) return '';
        if (trimmed.toLowerCase().startsWith('page ')) {
            const remainder = trimmed.slice(5).trim();
            if (remainder) return remainder;
        }
        return trimmed;
    }

    #pageNumberFromLabel(label) {
        if (typeof label !== 'string') return '';
        const match = label.match(/(\d+)/);
        if (!match) return '';
        const normalized = match[1]?.replace(/^0+/, '') ?? '';
        return normalized || '0';
    }

    #rendererSnapshotIndex() {
        const current = this.rendererPageSnapshot?.current;
        if (typeof current !== 'number') return null;
        return Math.max(0, current - 1);
    }

    #currentTotalPages(detail) {
        const candidates = [];
        if (this.totalPageCount > 0) {
            candidates.push({ source: 'page-targets', total: this.totalPageCount });
        }
        const rendererTotal = typeof this.rendererPageSnapshot?.total === 'number' ? this.rendererPageSnapshot.total : null;
        if (rendererTotal && rendererTotal > 0) {
            candidates.push({ source: 'renderer', total: rendererTotal });
        }
        if (typeof this.fallbackTotalPageCount === 'number' && this.fallbackTotalPageCount > 0) {
            candidates.push({ source: 'fallback', total: this.fallbackTotalPageCount });
        }
        const locationTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        if (locationTotal && locationTotal > 0) {
            candidates.push({ source: 'location', total: locationTotal });
        }
        if (!candidates.length) {
            this.lastTotalSource = null;
            return null;
        }
        const precedence = ['page-targets', 'renderer', 'fallback', 'location'];
        const best = candidates
            .sort((a, b) => {
                const pa = precedence.indexOf(a.source);
                const pb = precedence.indexOf(b.source);
                if (pa !== pb) return pa - pb; // lower index = higher priority
                return (b.total ?? 0) - (a.total ?? 0); // tie-break by larger total
            })[0];
        this.lastTotalSource = best?.source ?? null;
        if (best?.total && best.source !== 'page-targets') {
            this.#updateFallbackTotalPages(best.total);
        }
        return best?.total ?? null;
    }

    #updateFallbackTotalPages(total) {
        if (typeof total !== 'number' || total <= 0) return;
        if (!this.fallbackTotalPageCount || total > this.fallbackTotalPageCount) {
            this.fallbackTotalPageCount = total;
        }
    }

    #labelForDescriptor(descriptor) {
        if (!descriptor) return '';
        if (descriptor.pageItemKey && this.pageTargetIndexByKey?.has(descriptor.pageItemKey)) {
            return String((this.pageTargetIndexByKey.get(descriptor.pageItemKey) ?? 0) + 1);
        }
        const inferredTotal = this.totalPageCount
            || this.rendererPageSnapshot?.total
            || this.fallbackTotalPageCount
            || null;
        const indexFromFraction = this.#pageIndexFromFraction(descriptor.fraction, inferredTotal);
        if (indexFromFraction != null) {
            return String(indexFromFraction + 1);
        }
        if (typeof descriptor.fraction === 'number' && this.rendererPageSnapshot?.total) {
            const total = this.rendererPageSnapshot.total;
            const position = Math.max(1, Math.min(total, Math.round(descriptor.fraction * (total - 1)) + 1));
            return String(position);
        }
        if (descriptor.pageLabel) {
            const number = this.#pageNumberFromLabel(descriptor.pageLabel);
            if (number) return number;
            const sanitized = this.#sanitizePageLabel(descriptor.pageLabel);
            if (sanitized) return sanitized;
        }
        return '';
    }
    
    #isRelocateButtonVisible(direction) {
        if (!direction) return false;
        const button = this.navRelocateButtons?.[direction];
        return !!(button && !button.hidden && !button.disabled);
    }

    #updateRelocateButtons() {
        const backStack = this.relocateStacks.back;
        const forwardStack = this.relocateStacks.forward;
        const backBtn = this.navRelocateButtons?.back;
        const forwardBtn = this.navRelocateButtons?.forward;
        const scrubbing = !!this.scrubSession?.active;
        const busy = !!this.isProcessingRelocateJump;
        const showBack = !this.hideNavigationDueToScroll && backStack.length > 0;
        const showForward = !this.hideNavigationDueToScroll && forwardStack.length > 0;
        const disableBack = busy || !showBack;
        const disableForward = busy || !showForward;
        if (backBtn) {
            backBtn.hidden = !showBack;
            backBtn.disabled = disableBack;
            if (disableBack) {
                backBtn.setAttribute('aria-disabled', 'true');
            } else {
                backBtn.removeAttribute('aria-disabled');
            }
            if (!showBack) {
                backBtn.setAttribute('aria-hidden', 'true');
            } else {
                backBtn.removeAttribute('aria-hidden');
            }
        }
        if (forwardBtn) {
            forwardBtn.hidden = !showForward;
            forwardBtn.disabled = disableForward;
            if (disableForward) {
                forwardBtn.setAttribute('aria-disabled', 'true');
            } else {
                forwardBtn.removeAttribute('aria-disabled');
            }
            if (!showForward) {
                forwardBtn.setAttribute('aria-hidden', 'true');
            } else {
                forwardBtn.removeAttribute('aria-hidden');
            }
        }
        const backLabelDescriptor = this.#descriptorForRelocateLabel('back');
        const forwardLabelDescriptor = this.#descriptorForRelocateLabel('forward');
        if (this.navRelocateLabels?.back) {
            this.navRelocateLabels.back.textContent = showBack ? this.#labelForDescriptor(backLabelDescriptor) : '';
        }
        if (this.navRelocateLabels?.forward) {
            this.navRelocateLabels.forward.textContent = showForward ? this.#labelForDescriptor(forwardLabelDescriptor) : '';
        }
        this.#updateSectionProgress();
        if (this.previousRelocateVisibility.back !== showBack) {
            this.previousRelocateVisibility.back = showBack;
            this.#logJumpDiagnostic('relocate-visibility', {
                direction: 'back',
                visible: showBack,
                backDepth: backStack.length,
                hiddenDueToScroll: this.hideNavigationDueToScroll,
            });
        }
        if (this.previousRelocateVisibility.forward !== showForward) {
            this.previousRelocateVisibility.forward = showForward;
            this.#logJumpDiagnostic('relocate-visibility', {
                direction: 'forward',
                visible: showForward,
                forwardDepth: forwardStack.length,
                hiddenDueToScroll: this.hideNavigationDueToScroll,
            });
        }
    }
    
    #serializeStack(stack) {
        if (!Array.isArray(stack) || !stack.length) {
            return [];
        }
        const LIMIT = 5;
        const total = stack.length;
        const tail = stack.slice(-LIMIT);
        return tail.map((entry, offset) => {
            const index = total - tail.length + offset;
            return {
                index,
                fraction: typeof entry?.fraction === 'number' ? Number(entry.fraction.toFixed(6)) : null,
                pageKey: entry?.pageItemKey ?? null,
            };
        });
    }

    #logStackSnapshot(reason, extra = {}) {
        this.#logJumpDiagnostic('relocate-stack-snapshot', {
            reason,
            backDepth: this.relocateStacks?.back?.length ?? 0,
            forwardDepth: this.relocateStacks?.forward?.length ?? 0,
            backStack: this.#serializeStack(this.relocateStacks?.back),
            forwardStack: this.#serializeStack(this.relocateStacks?.forward),
            scrubActive: !!this.scrubSession?.active,
            pendingCommit: !!this.pendingScrubCommit,
            ...extra,
        });
    }

    #logRelocateDetail(_detail) {}

    #pruneBackStackIfReturnedToOrigin(detail) {
        if (!detail) return;
        const descriptor = this.#makeLocationDescriptor(detail);
        if (!descriptor) return;
        const reason = (detail.reason || '').toLowerCase();
        const isLiveScroll = reason === 'live-scroll';
        const phase = detail.liveScrollPhase ?? null;
        const canPrune = !isLiveScroll || phase === 'settled' || !phase;
        if (!canPrune) return;
        const backStack = this.relocateStacks.back;
        if (!backStack?.length) return;
        const lastEntry = backStack[backStack.length - 1];
        if (!lastEntry) return;
        if (!this.#isSameDescriptor(lastEntry, descriptor)) {
            return;
        }
        backStack.pop();
        this.#logPageScrub('pop', {
            index: backStack.length,
            reason: 'returned-to-origin-after-scrub',
            descriptorFraction: typeof descriptor.fraction === 'number' ? Number(descriptor.fraction.toFixed(6)) : null,
        });
        this.#logStackSnapshot('returned-to-origin');
        this.#updateRelocateButtons();
    }

    #maybeCommitPendingScrub(detail, descriptor, { updateButtons = true } = {}) {
        if (!this.pendingScrubCommit) return false;
        const { origin, reason, scheduledAt, releaseDescriptor, releaseFraction } = this.pendingScrubCommit;
        const phase = detail?.liveScrollPhase ?? null;
        const canCommit = !detail || detail.reason !== 'live-scroll' || phase === 'settled';
        if (!canCommit) return false;
        let effectiveDescriptor = descriptor || releaseDescriptor || null;
        if (!origin || !effectiveDescriptor) {
            this.pendingScrubCommit = null;
            this.#logPageScrub('pending-commit-skipped', {
                reason: 'missing-descriptor',
                releaseReason: reason ?? null,
            });
            return false;
        }
        const shouldSkipForOrigin = this.#isSameDescriptor(origin, effectiveDescriptor)
            && !(typeof releaseFraction === 'number' && typeof origin.fraction === 'number' && Math.abs(releaseFraction - origin.fraction) > FRACTION_EPSILON);
        if (shouldSkipForOrigin) {
            this.pendingScrubCommit = null;
            this.#logPageScrub('pending-commit-skipped', {
                reason: 'returned-to-origin',
                releaseReason: reason ?? null,
                descriptorFraction: typeof effectiveDescriptor?.fraction === 'number' ? Number(effectiveDescriptor.fraction.toFixed(6)) : null,
            });
            return false;
        }
        const result = this.#pushBackStack(origin, { stripCFI: true });
        if (result?.entry) {
            this.#logPageScrub('push', {
                index: result.index,
                fraction: result.entry?.fraction ?? null,
                reason: reason ?? 'pending-commit',
                commitPhase: phase ?? null,
                elapsedMs: scheduledAt ? Date.now() - scheduledAt : null,
                stackDepth: this.relocateStacks?.back?.length ?? null,
            });
            this.#logStackSnapshot('pending-commit', {
                commitReason: reason ?? 'pending-commit',
            });
        }
        this.pendingScrubCommit = null;
        if (updateButtons) {
            this.#updateRelocateButtons();
        }
        return !!result?.entry;
    }
    
    #finalizePendingRelocateJump(descriptor) {
        const pending = this.pendingRelocateJump;
        if (!pending) {
            this.isProcessingRelocateJump = false;
            return;
        }
        const direction = pending.direction;
        if (!direction) {
            this.pendingRelocateJump = null;
            this.isProcessingRelocateJump = false;
            return;
        }
        const targetFraction = typeof descriptor?.fraction === 'number' ? Number(descriptor.fraction.toFixed(6)) : null;
        const stack = this.relocateStacks?.[direction];
        if (stack?.length) {
            stack.pop();
        }
        const opposite = direction === 'back' ? 'forward' : 'back';
        if (pending.preJumpDescriptor) {
            const entry = this.#cloneDescriptor(pending.preJumpDescriptor);
            if (entry) {
                entry.cfi = null;
                const oppStack = this.relocateStacks?.[opposite];
                if (oppStack) {
                    oppStack.push(entry);
                    if (oppStack.length > MAX_RELOCATE_STACK) {
                        oppStack.shift();
                    }
                }
            }
        }
        this.pendingRelocateJump = null;
        this.isProcessingRelocateJump = false;
        this.#logJumpBack('jump-finalized', {
            direction,
            targetFraction,
            backDepth: this.relocateStacks?.back?.length ?? 0,
            forwardDepth: this.relocateStacks?.forward?.length ?? 0,
        });
        this.#logStackSnapshot('jump-finalized', {
            direction,
            targetFraction,
            backDepth: this.relocateStacks?.back?.length ?? 0,
            forwardDepth: this.relocateStacks?.forward?.length ?? 0,
        });
        this.#updateRelocateButtons();
    }
    
    async #handleRelocateJump(direction) {
        const stack = this.relocateStacks?.[direction];
        if (!stack?.length) {
            this.#logJumpBack('tap-ignored-empty', { direction });
            return;
        }
        if (this.hideNavigationDueToScroll) {
            this.#logJumpBack('tap-ignored-hidden', { direction });
            return;
        }
        if (this.pendingRelocateJump) {
            this.#logJumpBack('tap-ignored-pending', { direction });
            return;
        }
        const descriptor = this.#cloneDescriptor(stack[stack.length - 1]);
        if (!descriptor) {
            this.#logJumpBack('tap-ignored-nodescriptor', { direction });
            return;
        }
        const preJumpDescriptor = this.lastRelocateDetail
            ? this.#makeLocationDescriptor(this.lastRelocateDetail)
            : this.#cloneDescriptor(this.currentLocationDescriptor);
        const opposite = direction === 'back' ? 'forward' : 'back';
        const oppositeStack = this.relocateStacks?.[opposite];
        this.pendingRelocateJump = {
            direction,
            targetDescriptor: descriptor,
            preJumpDescriptor,
        };
        this.isProcessingRelocateJump = true;
        this.#updateRelocateButtons();
        const targetFraction = typeof descriptor?.fraction === 'number' ? Number(descriptor.fraction.toFixed(6)) : null;
        this.#logJumpBack('tap', {
            direction,
            stackDepth: stack.length,
            targetFraction,
            oppositeDepth: oppositeStack?.length ?? 0,
            hiddenDueToScroll: this.hideNavigationDueToScroll,
        });
        this.#logJumpDiagnostic('relocate-button', {
            direction,
            stackDepth: stack.length,
            hiddenDueToScroll: this.hideNavigationDueToScroll,
            targetFraction,
            oppositeDepth: oppositeStack?.length ?? 0,
        });
        this.#logStackSnapshot('button-prejump', {
            direction,
            targetFraction,
        });
        try {
            this.#logJumpBack('request', {
                direction,
                targetFraction,
                stackDepth: stack.length,
            });
            await this.onJumpRequest?.(descriptor);
            this.#logJumpBack('request-complete', {
                direction,
                targetFraction,
            });
        } catch (error) {
            console.error('Failed to navigate to saved location', error);
            this.#logJumpBack('error', {
                direction,
                message: error?.message ?? String(error),
            });
            this.pendingRelocateJump = null;
            this.isProcessingRelocateJump = false;
            this.#logStackSnapshot('button-error', { direction });
            this.#updateRelocateButtons();
        } finally {
            this.#logJumpBack('postjump', {
                direction,
                pending: !!this.pendingRelocateJump,
                processing: !!this.isProcessingRelocateJump,
            });
            this.#logStackSnapshot('button-postjump', { direction });
        }
    }
}
