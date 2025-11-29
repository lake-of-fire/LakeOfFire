const MAX_RELOCATE_STACK = 50;
const FRACTION_EPSILON = 0.000001;

// Focused pagination/bake diagnostics (capped to avoid spam)
let logEBookPageNumCounter = 0;
const LOG_EBOOK_PAGE_NUM_LIMIT = 400;
const MANABI_NAV_SENTINEL_ADJUST_ENABLED = true;
const NAV_PAGE_NUM_WHITELIST = new Set([
    'nav:set-page-targets',
    'nav:total-pages-source',
    'nav:page-metrics',
    'nav:relocate:input',
    'relocate',
    'relocate:label',
    'ui:primary-label',
    'ui:section-progress',
]);
const logEBookPageNumLimited = (event, detail = {}) => {
    const verbose = !!globalThis.manabiPageNumVerbose;
    const allow = verbose || NAV_PAGE_NUM_WHITELIST.has(event);
    if (!allow) return;
    if (logEBookPageNumCounter >= LOG_EBOOK_PAGE_NUM_LIMIT) return;
    logEBookPageNumCounter += 1;
    const payload = { event, count: logEBookPageNumCounter, ...detail };
    const line = `# EBOOKK PAGENUM ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
        try { console.log(line); } catch (_) {}
    }
};

// Stub logFix to avoid breaking when viewer.js isn't importing it here.
// We only need a no-op logger for nav diagnostics.
const logFix = (event, detail = {}) => {
    try {
        const payload = { event, ...detail };
        window.webkit?.messageHandlers?.print?.postMessage?.(`# EBOOKFIX1 ${JSON.stringify(payload)}`);
    } catch (_err) {
        try { console.log('# EBOOKFIX1', event, detail); } catch (_) {}
    }
};
const logBug = (event, detail = {}) => {
    try {
        const payload = { event, ...detail };
        window.webkit?.messageHandlers?.print?.postMessage?.(`# BOOKBUG1 ${JSON.stringify(payload)}`);
    } catch (_err) {
        try { console.log('# BOOKBUG1', event, detail); } catch (_) {}
    }
};

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
        this.sectionPageCounts = new Map();
        this.lastSectionIndexSeen = null;
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
        this.lastTotalPagesSnapshot = null;
        this.lastPageMetricsSnapshot = null;
        this.lastScrubberFraction = null;
        this.lastKnownLocationTotal = null;
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

    linearSectionCount = null;
    linearSectionIndexes = new Set();

    setIsRTL(isRTL) {
        this.isRTL = !!isRTL;
        this.#applyRelocateButtonEdges();
        this.#updateSectionProgress();
    }

    setSectionPageCountsFromCache(counts) {
        if (!(counts instanceof Map) || counts.size === 0) return;
        const linearCount = Array.isArray(this.navContext?.sections)
            ? this.navContext.sections.filter(s => s.linear !== 'no').length
            : null;
        if (typeof linearCount === 'number' && linearCount > 0 && counts.size < linearCount) {
            // Don't overwrite until all linear sections are known.
            logBug?.('pagecount:cachewarmer:skip-partial', {
                received: counts.size,
                linearCount,
            });
            return;
        }
        logBug?.('pagecount:cachewarmer:apply', {
            received: counts.size,
            linearCount,
            total: Array.from(counts.values()).reduce((a, v) => a + (Number.isFinite(v) ? v : 0), 0),
        });
        this.sectionPageCounts = new Map(counts);
        const total = Array.from(counts.values()).reduce((acc, v) => acc + (Number.isFinite(v) && v > 0 ? v : 0), 0);
        if (total > 0) {
            this.fallbackTotalPageCount = total;
            this.lastTotalSource = 'cachewarmer';
        }
        if (this.lastRelocateDetail) {
            this.#updateRendererSnapshotFromDetail(this.lastRelocateDetail);
            this.#updatePrimaryLine(this.lastRelocateDetail);
        }
        this.#updateSectionProgress({ refreshSnapshot: false });
        this.#updateRelocateButtons();
    }

    setPageTargets(pageList) {
        this.sectionPageCounts.clear?.();
        this.lastSectionIndexSeen = null;
        this.lastScrubberFraction = null;
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
        const pageKeyPreview = this.pageTargets.slice(0, 5).map((item, index) => ({
            idx: index,
            key: ensurePageKey(item, index),
            label: item?.label ?? null,
        }));
        this.#logPageNumberDiagnostic('set-page-targets', {
            pageTargetCount: this.totalPageCount,
        });
        logEBookPageNumLimited('nav:set-page-targets', {
            pageTargetCount: this.totalPageCount,
            preview: pageKeyPreview,
            totalSource: this.lastTotalSource ?? null,
        });
        if (this.lastRelocateDetail) {
            this.#updatePrimaryLine(this.lastRelocateDetail);
        }
    }
    
    setNavContext(context) {
        this.navContext = context ?? null;
        this.linearSectionIndexes = new Set();
        if (Array.isArray(this.navContext?.sections)) {
            this.navContext.sections.forEach((section, idx) => {
                if (section?.linear !== 'no') this.linearSectionIndexes.add(idx);
            });
        }
        this.linearSectionCount = this.linearSectionIndexes.size || null;
        this.#toggleCompletionStack();
        this.#updateSectionProgress();
        this.#updateRelocateButtons();
    }
    
    setHideNavigationDueToScroll(shouldHide) {
        this.hideNavigationDueToScroll = !!shouldHide;
        this.navBar?.classList.toggle('nav-hidden-due-to-scroll', this.hideNavigationDueToScroll);
        logBug?.('navhud-hide', {
            shouldHide: this.hideNavigationDueToScroll,
            navHiddenClass: this.navBar?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
        });
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
        const locCurrent = typeof detail?.location?.current === 'number' ? detail.location.current : null;
        const locTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        if (locTotal != null && locTotal > 0) {
            this.lastKnownLocationTotal = locTotal;
        }
        // Ensure section index is preserved for per-section totals/offsets
        const rendererIndex = (() => {
            try {
                const r = this.getRenderer?.();
                return typeof r?.currentIndex === 'number' ? r.currentIndex : null;
            } catch (_) { return null }
        })();
        const inferredSectionIndex = (() => {
            if (typeof detail.sectionIndex === 'number') return detail.sectionIndex;
            if (typeof detail.index === 'number') return detail.index;
            if (typeof rendererIndex === 'number') return rendererIndex;
            if (typeof this.lastRelocateDetail?.sectionIndex === 'number') return this.lastRelocateDetail.sectionIndex;
            if (typeof this.lastRelocateDetail?.index === 'number') return this.lastRelocateDetail.index;
            if (typeof this.lastSectionIndexSeen === 'number') return this.lastSectionIndexSeen;
            return null;
        })();
        if (typeof inferredSectionIndex === 'number') {
            detail.sectionIndex = inferredSectionIndex;
            this.lastSectionIndexSeen = inferredSectionIndex;
        }
        if (typeof detail.sectionIndex === 'number' && typeof detail.pageCount === 'number' && detail.pageCount > 0) {
            this.sectionPageCounts.set(detail.sectionIndex, detail.pageCount);
        }
        logEBookPageNumLimited('nav:relocate:input', {
            sectionIndex: typeof detail.sectionIndex === 'number' ? detail.sectionIndex : null,
            index: typeof detail.index === 'number' ? detail.index : null,
            pageNumber: typeof detail.pageNumber === 'number' ? detail.pageNumber : null,
            pageCount: typeof detail.pageCount === 'number' ? detail.pageCount : null,
            scrolled: detail.scrolled ?? null,
            sectionPageCountsSize: this.sectionPageCounts.size,
            rendererIndex,
        });
        // Prefer the renderer's live snapshot, but prime it from detail when available
        this.#updateRendererSnapshotFromDetail(detail);
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

    #updateRendererSnapshotFromDetail(detail) {
        const scrolled = detail?.scrolled;
        const pageNumber = typeof detail?.pageNumber === 'number' ? detail.pageNumber : null;
        const pageCount = typeof detail?.pageCount === 'number' ? detail.pageCount : null;
        // Only trust detail counts when renderer is paginated (scrolled === false) and counts are positive.
        if (scrolled === false && pageNumber != null && pageNumber > 0 && pageCount != null && pageCount > 0) {
            const normalized = {
                current: Math.min(pageCount, Math.max(1, Math.round(pageNumber))),
                total: Math.max(1, Math.round(pageCount)),
                rawCurrent: Math.round(pageNumber),
                rawTotal: Math.round(pageCount),
                scrolled,
            };
            this.rendererPageSnapshot = normalized;
            this.#updateFallbackTotalPages(normalized.total);
            logEBookPageNumLimited('nav:renderer-snapshot:detail', {
                detailPage: pageNumber,
                detailTotal: pageCount,
                normalizedCurrent: normalized.current,
                normalizedTotal: normalized.total,
                scrolled,
                totalPageCount: this.totalPageCount,
                totalSource: this.lastTotalSource ?? null,
            });
        }
    }
    
    #updatePrimaryLine(detail) {
        const fullLabelTarget = this.navPrimaryTextFull ?? this.navPrimaryText;
        const compactLabelTarget = this.navPrimaryTextCompact ?? this.navPrimaryText;
        if (!fullLabelTarget || !compactLabelTarget) return;

        const scrubFrozenLabel = this.scrubSession?.active ? this.scrubSession.frozenLabel : null;
        const fullLabelCandidate = this.formatPrimaryLabel(detail, { allowRendererFallback: false });
        const rawLabel = fullLabelCandidate || scrubFrozenLabel || '';
        const displayLabel = rawLabel ? this.#condensePrimaryLabel(rawLabel.replace(/^Loc\\s+/i, 'Loc ')) : '';

        // Show compact when nav hidden; full when visible. Never both.
        const showCompact = this.hideNavigationDueToScroll;
        fullLabelTarget.textContent = showCompact ? '' : displayLabel;
        compactLabelTarget.textContent = showCompact ? displayLabel : '';

        if (fullLabelCandidate) {
            this.latestPrimaryLabel = fullLabelCandidate;
        }

        // UI surface logging: what the user actually sees on the nav bar.
        logEBookPageNumLimited('ui:primary-label', {
            label: fullLabelTarget.textContent || '',
            compactLabel: compactLabelTarget.textContent || '',
            source: this.lastPrimaryLabelDiagnostics?.source ?? null,
            current: this.lastPrimaryLabelDiagnostics?.candidateIndex != null
                ? this.lastPrimaryLabelDiagnostics.candidateIndex + 1
                : null,
            total: null, // never report totals to UI log to avoid confusion with Loc
            rendererSnapshotCurrent: this.rendererPageSnapshot?.current ?? null,
            rendererSnapshotTotal: this.rendererPageSnapshot?.total ?? null,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
        });
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

    formatPrimaryLabel(detail, { allowRendererFallback = false, condensedOnly = false } = {}) {
        const derived = this.#derivePrimaryLabel(detail);
        if (derived) {
            const label = condensedOnly ? this.#condensePrimaryLabel(derived) : derived;
            if (!condensedOnly) {
                this.latestPrimaryLabel = label;
            }
            return label;
        }
        // No fallback to page-based labels.
        return '';
    }

    getPrimaryDisplayLabel(detail) {
        const label = this.formatPrimaryLabel(detail, { allowRendererFallback: false });
        return label ?? '';
    }

    getPageEstimate(detail) {
        // Only use location-derived current/total; ignore page-based metrics.
        const locCurrent = typeof detail?.location?.current === 'number' ? detail.location.current : null;
        const locTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        if (locCurrent == null && locTotal == null) return null;
        return { current: locCurrent != null ? locCurrent + 1 : null, total: locTotal };
    }

    getLocationTotalHint() {
        return this.lastKnownLocationTotal
            ?? this.lastPrimaryLabelDiagnostics?.locationTotal
            ?? null;
    }

    getScrubberFraction(detail = null) {
        if (detail) {
            const metrics = this.#computePageMetrics(detail);
            const computed = this.lastScrubberFraction
                ?? this.#scrubberFractionFromMetrics({
                    current: metrics?.currentPageNumber,
                    total: metrics?.totalPages,
                    fallbackFraction: typeof detail.fraction === 'number' ? detail.fraction : null,
                });
            if (computed != null) {
                this.lastScrubberFraction = computed;
            }
            return computed;
        }
        return this.lastScrubberFraction;
    }

    #scrubberFractionFromMetrics({ current, total, fallbackFraction }) {
        if (typeof total === 'number' && total > 1 && typeof current === 'number') {
            const clampedCurrent = Math.max(1, Math.min(total, current));
            const numerator = clampedCurrent - 1;
            return Math.max(0, Math.min(1, numerator / (total - 1)));
        }
        if (typeof fallbackFraction === 'number' && isFinite(fallbackFraction)) {
            return Math.max(0, Math.min(1, fallbackFraction));
        }
        return null;
    }

    #derivePrimaryLabel(detail) {
        if (!detail) {
            this.lastPrimaryLabelDiagnostics = {
                source: 'no-detail',
                label: '',
                totalPageCount: this.totalPageCount,
            };
            return null;
        }

        // Prefer location-based "Loc" display only.
        const locCurrent = typeof detail.location?.current === 'number' ? detail.location.current : null;
        const locTotal = typeof detail.location?.total === 'number' ? detail.location.total : null;
        if (locCurrent != null) {
            const label = locTotal != null
                ? `Loc ${locCurrent + 1} of ${locTotal}`
                : `Loc ${locCurrent + 1}`;
            this.lastPrimaryLabelDiagnostics = {
                source: 'location-loc',
                label,
                locationCurrent: locCurrent,
                locationTotal: locTotal,
                totalPageCount: this.totalPageCount,
            };
            this.latestPrimaryLabel = label;
            return label;
        }

        // If no location data, we won't show a label.
        this.latestPrimaryLabel = '';
        this.lastPrimaryLabelDiagnostics = {
            source: 'no-location',
            label: '',
            totalPageCount: this.totalPageCount,
        };
        return null;
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
        const sectionIndex = typeof detail.sectionIndex === 'number'
            ? detail.sectionIndex
            : (typeof detail.index === 'number' ? detail.index : null);
        const locationCurrent = typeof detail.location?.current === 'number' ? detail.location.current : null;
        const locationTotal = typeof detail.location?.total === 'number' ? detail.location.total : null;
        const detailPageNumber = typeof detail.pageNumber === 'number' ? detail.pageNumber : null;
        const detailPageCount = typeof detail.pageCount === 'number' ? detail.pageCount : null;
        const totalPagesRaw = this.#currentTotalPages(detail, detailPageCount);
        const approxIndexFromFraction = this.#pageIndexFromFraction(fraction, detailPageCount ?? totalPagesRaw);
        const locationIndex = locationCurrent != null ? locationCurrent : null;
        const rendererIndex = this.#rendererSnapshotIndex();
        const detailIndex = detailPageNumber != null ? detailPageNumber - 1 : null;
        // Prefer relocate detail first, then explicit page target, then renderer, then fraction
        const candidateIndex = [detailIndex, pageIndex, rendererIndex, approxIndexFromFraction, locationIndex]
            .find(index => typeof index === 'number' && index >= 0);
        const sectionPageNumber = candidateIndex != null ? candidateIndex + 1 : null;

        // Track per-section counts and compute cross-section offset
        if (sectionIndex != null && detailPageCount != null) {
            this.sectionPageCounts.set(sectionIndex, detailPageCount);
            logFix('pagecount:section:set', {
                sectionIndex,
                pageCount: detailPageCount,
                totalTracked: this.sectionPageCounts.size,
            });
        }
        const sectionOffset = sectionIndex != null ? this.#sectionOffset(sectionIndex) : 0;
        const sectionsTotal = this.sectionPageCounts.size > 0
            ? Array.from(this.sectionPageCounts.values()).reduce((acc, value) => acc + (typeof value === 'number' && value > 0 ? value : 0), 0)
            : null;

        const adjustedCurrent = sectionPageNumber != null ? sectionPageNumber + sectionOffset : null;
        const adjustedTotal = totalPagesRaw != null
            ? totalPagesRaw
            : (sectionOffset + (detailPageCount ?? 0) || null);
        logFix('pagemetrics', {
            sectionIndex,
            sectionOffset,
            sectionPageNumber,
            sectionPageCount: detailPageCount,
            detailPageNumber,
            detailPageCount,
            totalPagesRaw,
            adjustedCurrent,
            adjustedTotal,
            candidateIndex,
            fraction,
        });
        const diag = {
            fraction,
            pageItemKey,
            pageItemLabel,
            pageIndexFromItem: pageIndex,
            approxIndexFromFraction,
            locationCurrent,
            locationTotal,
            candidateIndex,
            sectionIndex,
            sectionOffset,
            sectionPageNumber,
            sectionPageCount: detailPageCount,
            detailPageNumber,
            detailPageCount,
            totalPageCount: this.totalPageCount,
            fallbackTotalPageCount: this.fallbackTotalPageCount,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            rendererSnapshotCurrent: this.rendererPageSnapshot?.current ?? null,
            rendererSnapshotTotal: this.rendererPageSnapshot?.total ?? null,
            effectiveTotalPages: adjustedTotal ?? null,
            totalSource: this.lastTotalSource ?? null,
            currentPageNumber: adjustedCurrent ?? null,
            totalPages: adjustedTotal ?? null,
        };
        const scrubFraction = this.#scrubberFractionFromMetrics({
            current: adjustedCurrent,
            total: adjustedTotal,
            fallbackFraction: fraction,
        });
        if (scrubFraction != null) {
            this.lastScrubberFraction = scrubFraction;
        }
        this.#logPageMetrics({
            fraction: fraction != null ? Number(fraction.toFixed(6)) : null,
            pageItemKey,
            pageItemLabel,
            pageIndexFromItem: pageIndex,
            approxIndexFromFraction,
            locationIndex: locationCurrent,
            rendererIndex,
            candidateIndex,
            sectionIndex,
            sectionOffset,
            currentPageNumber: adjustedCurrent,
            totalPages: adjustedTotal,
            totalPageCount: this.totalPageCount,
            rendererTotal: this.rendererPageSnapshot?.total ?? null,
            fallbackTotalPageCount: this.fallbackTotalPageCount,
            sectionsTotal,
            locationTotal,
            detailPageNumber,
            detailPageCount,
            totalSource: this.lastTotalSource ?? null,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
        });
        return {
            currentPageNumber: adjustedCurrent,
            totalPages: adjustedTotal,
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
            logEBookPageNumLimited('ui:section-progress', {
                label,
                pagesLeft,
                target: targetKey,
                rendererCurrent: this.rendererPageSnapshot?.current ?? null,
                rendererTotal: this.rendererPageSnapshot?.total ?? null,
                hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            });
        } catch (error) {
            console.error('Failed to update section progress', error);
        }
    }

    
    async #calculatePagesLeftInSection({ refreshSnapshot = true } = {}) {
        // Prefer relocate detail (already normalized to text pages) when available in paginated mode.
        const detail = this.lastRelocateDetail;
        if (detail?.scrolled === false) {
            const current = typeof detail.pageNumber === 'number' ? detail.pageNumber : null;
            const total = typeof detail.pageCount === 'number' ? detail.pageCount : null;
            if (current != null && current > 0 && total != null && total > 0) {
                return Math.max(0, total - current);
            }
        }
        if (refreshSnapshot) {
            await this.#refreshRendererSnapshot();
        }
        if (!this.rendererPageSnapshot || !this.rendererPageSnapshot.total || this.rendererPageSnapshot.total <= 0) return null;
        return Math.max(0, this.rendererPageSnapshot.total - this.rendererPageSnapshot.current);
    }
    
    #handleRelocateHistory(detail) {
        const descriptor = this.#makeLocationDescriptor(detail);
        if (!descriptor) return;
        const lastOrigin = this.scrubSession?.originDescriptor;
        // If the relocate matches the scrub origin immediately after a jump, don't clobber history yet.
        if (this.scrubSession?.pendingCommit && lastOrigin && this.#isSameDescriptor(lastOrigin, descriptor)) {
            logFix('jumpback:skip-origin-relocate', {
                reason: detail?.reason ?? null,
                fraction: descriptor?.fraction ?? null,
            });
            this.scrubSession.pendingCommit = false;
            this.currentLocationDescriptor = descriptor;
            return;
        }
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
        const isPageTurn = reason === 'page';
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
                logFix('jumpback:push', {
                    reason,
                    liveScrollPhase,
                    backDepth: this.relocateStacks.back.length,
                    descriptorFraction: descriptor?.fraction ?? null,
                    prevFraction: previousDescriptor?.fraction ?? null,
                });
                logBug('EBOOKJUMP', {
                    event: 'push',
                    reason,
                    backDepth: this.relocateStacks.back.length,
                    forwardDepth: this.relocateStacks.forward.length,
                    prevFraction: previousDescriptor?.fraction ?? null,
                    newFraction: descriptor?.fraction ?? null,
                });
            }
        } else if (isPageTurn && descriptorChanged && !isScrubbing && previousDescriptor) {
            this.#pushBackStack(previousDescriptor);
            logFix('jumpback:push:pageturn', {
                reason,
                backDepth: this.relocateStacks.back.length,
                descriptorFraction: descriptor?.fraction ?? null,
                prevFraction: previousDescriptor?.fraction ?? null,
                sectionIndex: detail?.sectionIndex ?? null,
            });
            logBug('EBOOKJUMP', {
                event: 'push-pageturn',
                reason,
                backDepth: this.relocateStacks.back.length,
                forwardDepth: this.relocateStacks.forward.length,
                prevFraction: previousDescriptor?.fraction ?? null,
                newFraction: descriptor?.fraction ?? null,
                sectionIndex: detail?.sectionIndex ?? null,
            });
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
            logFix('scrub:origin-set', {
                originFraction: session.originFraction ?? null,
                descriptorFraction: descriptor?.fraction ?? null,
            });
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
        logBug('EBOOKJUMP', {
            event: 'stack-push',
            index,
            backDepth: backStack.length,
            forwardDepth: this.relocateStacks.forward.length,
            fraction: entry.fraction ?? null,
        });
        this.#logStackSnapshot('push');
        return { entry, index };
    }
    
    #makeLocationDescriptor(detail) {
        if (!detail) return null;
        const locCurrent = typeof detail?.location?.current === 'number' ? detail.location.current : null;
        const locTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        const location = (locCurrent != null || locTotal != null)
            ? { current: locCurrent, total: locTotal }
            : null;
        const locationTotalHint = locTotal != null ? locTotal : (this.lastKnownLocationTotal ?? null);
        return {
            cfi: detail.cfi ?? null,
            fraction: typeof detail.fraction === 'number' ? detail.fraction : null,
            pageItemKey: detail.pageItem ? ensurePageKey(detail.pageItem) : null,
            pageLabel: typeof detail.pageItem?.label === 'string' ? detail.pageItem.label : null,
            location,
            locationTotalHint,
        };
    }

    #descriptorFromFraction(fraction) {
        if (typeof fraction !== 'number' || !isFinite(fraction)) return null;
        const locTotal = this.lastKnownLocationTotal ?? this.lastPrimaryLabelDiagnostics?.locationTotal ?? null;
        const hasTotal = typeof locTotal === 'number' && locTotal > 0;
        const clampedTotal = hasTotal ? Math.max(1, locTotal) : null;
        const location = hasTotal
            ? {
                total: clampedTotal,
                current: Math.round(Math.max(0, Math.min(1, fraction)) * (clampedTotal - 1)),
            }
            : null;
        return {
            cfi: null,
            fraction,
            pageItemKey: null,
            pageLabel: null,
            location,
            locationTotalHint: hasTotal ? clampedTotal : null,
        };
    }

    #cloneDescriptor(descriptor) {
        if (!descriptor) return null;
        return {
            cfi: descriptor.cfi ?? null,
            fraction: typeof descriptor.fraction === 'number' ? descriptor.fraction : null,
            pageItemKey: descriptor.pageItemKey ?? null,
            pageLabel: descriptor.pageLabel ?? null,
            location: descriptor.location ? { ...descriptor.location } : null,
            locationTotalHint: typeof descriptor.locationTotalHint === 'number' ? descriptor.locationTotalHint : null,
        };
    }
    
    #requestRendererPrimaryLine() {
        // No-op: we no longer backfill the primary label with renderer page numbers.
        return;
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
        const scrolled = renderer?.scrolled ?? null;
        const isPaginated = renderer && scrolled === false;
        const snapshotBeforeAdjust = {
            rawPage,
            rawTotal,
            numericPage,
            numericTotal,
            totalBase: total,
            currentBase,
            clampedCurrent: current,
            scrolled,
            rtl: renderer?.isRTL ?? renderer?.bookDir === 'rtl' ?? null,
        };
        const shouldAdjustForSentinels = MANABI_NAV_SENTINEL_ADJUST_ENABLED && isPaginated && total && total > 2;
        if (shouldAdjustForSentinels) {
            const textTotal = Math.max(1, total - 2); // strip lead/trail sentinels
            const textCurrent = Math.max(1, Math.min(textTotal, current)); // clamp without subtracting so page 2 -> text page 2
            logEBookPageNumLimited('nav:normalize:calc', {
                ...snapshotBeforeAdjust,
                mode: 'text-only',
                textCurrent,
                textTotal,
                returnedCurrent: textCurrent,
                returnedTotal: textTotal,
            });
            return {
                current: textCurrent,
                total: textTotal,
                rawCurrent: current,
                rawTotal: total,
                scrolled,
            };
        }
        logEBookPageNumLimited('nav:normalize:calc', {
            ...snapshotBeforeAdjust,
            mode: 'raw',
            returnedCurrent: current,
            returnedTotal: total,
        });
        return {
            current,
            total,
            rawCurrent: current,
            rawTotal: total,
            scrolled,
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
            logEBookPageNumLimited('nav:renderer-snapshot:inputs', {
                rawPage: pageResult.value,
                rawTotal: pagesResult.value,
                normalizedCurrent: normalized.current,
                normalizedTotal: normalized.total,
                rawCurrent: normalized.rawCurrent,
                rawTotal: normalized.rawTotal,
                isPaginated: renderer?.scrolled === false,
                scrolled: renderer?.scrolled ?? null,
                rtl: renderer?.isRTL ?? renderer?.bookDir === 'rtl' ?? null,
                currentBase: normalized.rawCurrent,
                totalBase: normalized.rawTotal,
            });
            this.#logPageNumberDiagnostic('renderer-snapshot', {
                rendererCurrent: normalized.current,
                rendererTotal: normalized.total,
                rawRendererCurrent: normalized.rawCurrent,
                rawRendererTotal: normalized.rawTotal,
            });
            logEBookPageNumLimited('nav:renderer-snapshot', {
                rawPage: pageResult.value,
                rawTotal: pagesResult.value,
                normalizedCurrent: normalized.current,
                normalizedTotal: normalized.total,
                rawCurrent: normalized.rawCurrent,
                rawTotal: normalized.rawTotal,
                scrolled: renderer?.scrolled ?? null,
                rtl: renderer?.isRTL ?? renderer?.bookDir === 'rtl' ?? null,
                totalPageCount: this.totalPageCount,
                totalSource: this.lastTotalSource ?? null,
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
        const pageNumber = typeof this.lastPrimaryLabelDiagnostics?.currentPageNumber === 'number'
            ? this.lastPrimaryLabelDiagnostics.currentPageNumber
            : null;
        const pageTotal = typeof this.lastPrimaryLabelDiagnostics?.totalPages === 'number'
            ? this.lastPrimaryLabelDiagnostics.totalPages
            : null;
        const context = {
            timestamp: Date.now(),
            pageNumber,
            pageTotal,
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
        const scrolled = this.rendererPageSnapshot?.scrolled;
        if (scrolled !== false) return null; // only trust renderer index in paginated mode
        const current = this.rendererPageSnapshot?.current;
        if (typeof current !== 'number') return null;
        return Math.max(0, current - 1);
    }

    #sectionOffset(sectionIndex) {
        if (sectionIndex == null || sectionIndex <= 0) return 0;
        let sum = 0;
        for (let i = 0; i < sectionIndex; i += 1) {
            const count = this.sectionPageCounts.get(i);
            if (typeof count === 'number' && count > 0) {
                sum += count;
            } else {
                break; // stop at first gap to avoid overstating
            }
        }
        return sum;
    }

    #hasCompleteSectionCounts() {
        if (!this.linearSectionCount || this.linearSectionCount <= 0) return false;
        let filled = 0;
        for (const idx of this.linearSectionIndexes) {
            if (this.sectionPageCounts.has(idx)) filled += 1;
        }
        return filled === this.linearSectionCount;
    }

    #currentTotalPages(detail, detailPageCount) {
        const candidates = [];
        if (this.totalPageCount > 0) {
            candidates.push({ source: 'page-targets', total: this.totalPageCount });
        }
        if (this.sectionPageCounts.size > 0 && this.#hasCompleteSectionCounts()) {
            const sectionSum = Array.from(this.sectionPageCounts.values())
                .reduce((acc, value) => acc + (typeof value === 'number' && value > 0 ? value : 0), 0);
            if (sectionSum > 0) {
                candidates.push({ source: 'sections', total: sectionSum });
            }
        }
        if (typeof detailPageCount === 'number' && detailPageCount > 0) {
            candidates.push({ source: 'detail', total: detailPageCount });
        }
        const rendererTotal = typeof this.rendererPageSnapshot?.total === 'number' ? this.rendererPageSnapshot.total : null;
        const rendererScrolled = this.rendererPageSnapshot?.scrolled ?? null;
        // Renderer totals are only trustworthy in paginated mode.
        if (rendererTotal && rendererTotal > 0 && rendererScrolled === false) {
            candidates.push({ source: 'renderer', total: rendererTotal });
        }
        const locationTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        if (locationTotal && locationTotal > 0) {
            candidates.push({ source: 'location', total: locationTotal });
        }
        if (typeof this.fallbackTotalPageCount === 'number' && this.fallbackTotalPageCount > 0) {
            candidates.push({ source: 'fallback', total: this.fallbackTotalPageCount });
        }
        if (!candidates.length) {
            this.lastTotalSource = null;
            return null;
        }
        const precedence = ['page-targets', 'sections', 'fallback', 'renderer', 'detail', 'location'];
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
        logBug('total-pages-choice', {
            chosenSource: best?.source ?? null,
            chosenTotal: best?.total ?? null,
            candidates: candidates.map(({ source, total }) => ({ source, total })),
            sectionsComplete: this.#hasCompleteSectionCounts(),
            linearSectionCount: this.linearSectionCount ?? null,
        });
        const summary = candidates.map(({ source, total }) => ({ source, total }));
        const changed = !this.lastTotalPagesSnapshot
            || this.lastTotalPagesSnapshot.source !== (best?.source ?? null)
            || this.lastTotalPagesSnapshot.total !== (best?.total ?? null)
            || this.lastTotalPagesSnapshot.candidateCount !== summary.length;
        if (changed) {
            logEBookPageNumLimited('nav:total-pages-source', {
                chosenSource: best?.source ?? null,
                chosenTotal: best?.total ?? null,
                candidates: summary,
            });
            this.lastTotalPagesSnapshot = {
                source: best?.source ?? null,
                total: best?.total ?? null,
                candidateCount: summary.length,
            };
        }
        return best?.total ?? null;
    }

    #logPageMetrics(payload) {
        const epsilon = 0.00001;
        const prev = this.lastPageMetricsSnapshot;
        const hasChanged =
            !prev ||
            prev.currentPageNumber !== payload.currentPageNumber ||
            prev.totalPages !== payload.totalPages ||
            prev.candidateIndex !== payload.candidateIndex ||
            prev.totalSource !== payload.totalSource ||
            prev.sectionOffset !== payload.sectionOffset ||
            prev.sectionIndex !== payload.sectionIndex ||
            (typeof payload.fraction === 'number' && typeof prev?.fraction === 'number'
                ? Math.abs(payload.fraction - prev.fraction) > epsilon
                : payload.fraction !== prev?.fraction);
        if (!hasChanged) return;
        this.lastPageMetricsSnapshot = {
            currentPageNumber: payload.currentPageNumber,
            totalPages: payload.totalPages,
            candidateIndex: payload.candidateIndex,
            totalSource: payload.totalSource ?? null,
            sectionOffset: payload.sectionOffset ?? null,
            sectionIndex: payload.sectionIndex ?? null,
            fraction: payload.fraction ?? null,
        };
        logEBookPageNumLimited('nav:page-metrics', payload);
    }

    #updateFallbackTotalPages(total) {
        if (typeof total !== 'number' || total <= 0) return;
        if (!this.fallbackTotalPageCount || total > this.fallbackTotalPageCount) {
            this.fallbackTotalPageCount = total;
        }
    }

    // Public wrapper so external callers (e.g., scrubber live updates) can format labels without accessing private fields.
    labelForDescriptor(descriptor) {
        return this.#labelForDescriptor(descriptor);
    }

    #labelForDescriptor(descriptor) {
        if (!descriptor) return '';
        const locCurrent = typeof descriptor.location?.current === 'number' ? descriptor.location.current : null;
        if (locCurrent != null) {
            return `${locCurrent + 1}`;
        }
        // No location info; leave label empty.
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
            if (!showBack) backBtn.setAttribute('aria-hidden', 'true');
            else backBtn.removeAttribute('aria-hidden');
        }
        if (forwardBtn) {
            forwardBtn.hidden = !showForward;
            forwardBtn.disabled = disableForward;
            if (disableForward) {
                forwardBtn.setAttribute('aria-disabled', 'true');
            } else {
                forwardBtn.removeAttribute('aria-disabled');
            }
            if (!showForward) forwardBtn.setAttribute('aria-hidden', 'true');
            else forwardBtn.removeAttribute('aria-hidden');
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
        logBug('EBOOKJUMP', {
            event: 'jump-finalized',
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
            logBug('EBOOKJUMP', { event: 'tap-empty', direction });
            return;
        }
        if (this.hideNavigationDueToScroll) {
            this.#logJumpBack('tap-ignored-hidden', { direction });
            logBug('EBOOKJUMP', { event: 'tap-hidden', direction });
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
