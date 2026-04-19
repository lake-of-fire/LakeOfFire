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

const logNavHide = (event, detail = {}) => {
    const payload = { event, ...detail };
    const line = `# EBOOK NAVHIDE ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
        try { console.log(line); } catch (_) {}
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
        this.navPrimaryPercent = document.getElementById('nav-primary-percent');
        this.navHiddenOverlay = {
            text: document.getElementById('nav-hidden-primary-text'),
            percent: document.getElementById('nav-hidden-primary-percent'),
        };
        this.navSectionProgress = {
            leading: document.getElementById('nav-section-progress-leading'),
            trailing: document.getElementById('nav-section-progress-trailing'),
            center: document.getElementById('nav-section-progress-center'),
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
        this.pageTrackingContainer = document.getElementById('page-tracking-container');
        this.pageTrackingButtons = document.getElementById('page-tracking-buttons');
        
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
        this.navHidden = false;
        this._applyLabelVariant();
        if (this.pendingScrubCommit) {
            this._logPageScrub('pending-commit-reset', {
                reason: 'new-scrub',
            });
            this.pendingScrubCommit = null;
        }

        this.navRelocateButtons.back?.addEventListener('click', () => this._handleRelocateJump('back'));
        this.navRelocateButtons.forward?.addEventListener('click', () => this._handleRelocateJump('forward'));
        this._updateRelocateButtons();
        this._applyRelocateButtonEdges();
    }

    _logJumpBack(event, payload = {}) {
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

    _logJumpButton(event, payload = {}) {
        const cleanedEntries = Object.entries(payload ?? {}).filter(([, value]) => value !== undefined);
        const metadata = cleanedEntries.length ? JSON.stringify(Object.fromEntries(cleanedEntries)) : '';
        const line = metadata ? `# JUMPTOBUTTON ${event} ${metadata}` : `# JUMPTOBUTTON ${event}`;
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
        this._applyRelocateButtonEdges();
        this._updateSectionProgress();
        this._updateAuxiliaryInsets();
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
            this._updateRendererSnapshotFromDetail(this.lastRelocateDetail);
            this._updatePrimaryLine(this.lastRelocateDetail);
        }
        this._updateSectionProgress({ refreshSnapshot: false });
        this._updateRelocateButtons();
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
        this._logPageNumberDiagnostic('set-page-targets', {
            pageTargetCount: this.totalPageCount,
        });
        logEBookPageNumLimited('nav:set-page-targets', {
            pageTargetCount: this.totalPageCount,
            preview: pageKeyPreview,
            totalSource: this.lastTotalSource ?? null,
        });
        if (this.lastRelocateDetail) {
            this._updatePrimaryLine(this.lastRelocateDetail);
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
        this._toggleCompletionStack();
        this._updateSectionProgress();
        this._updateRelocateButtons();
    }
    
    setHideNavigationDueToScroll(shouldHide, source = 'unknown', context = null) {
        const previous = this.hideNavigationDueToScroll;
        this.hideNavigationDueToScroll = !!shouldHide;
        this.navBar?.classList.toggle('nav-hidden-due-to-scroll', this.hideNavigationDueToScroll);
        this._applyLabelVariant();
        logNavHide('hud:set-hide', {
            shouldHide: this.hideNavigationDueToScroll,
            previous,
            source,
            navHiddenClass: this.navBar?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            progressWrapperHidden: this.progressWrapper?.getAttribute?.('aria-hidden') ?? null,
            context,
        });
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
            this._updatePrimaryLine(this.lastRelocateDetail);
        }
        this._updateRelocateButtons();
        globalThis.reader?.queueLayoutDiagnostics?.('nav-hide-due-to-scroll', {
            source,
            shouldHide: this.hideNavigationDueToScroll,
        });
    }

    // External toggle for full nav hide (not the scroll HUD hide).
    setNavHiddenState(shouldHide) {
        this.navHidden = !!shouldHide;
        this._applyLabelVariant();
        const descriptor = this.lastRelocateDetail || this.currentLocationDescriptor;
        if (descriptor) {
            this._updatePrimaryLine(descriptor);
        }
        globalThis.reader?.queueLayoutDiagnostics?.('nav-hidden-state', {
            shouldHide: this.navHidden,
        });
    }

    getCurrentDescriptor() {
        return this._cloneDescriptor(this.currentLocationDescriptor);
    }

    beginProgressScrubSession(originDescriptor) {
        if (this.pendingScrubCommit) {
            const fallbackDescriptor = this._cloneDescriptor(this.currentLocationDescriptor);
            if (fallbackDescriptor) {
                const flushed = this._maybeCommitPendingScrub({
                    reason: 'scrub-begin-flush',
                    liveScrollPhase: 'settled',
                }, fallbackDescriptor);
                if (!flushed && this.pendingScrubCommit) {
                    this._logPageScrub('pending-commit-awaiting-detail', {
                        reason: 'scrub-begin',
                        pendingOriginFraction: typeof this.pendingScrubCommit?.origin?.fraction === 'number'
                            ? Number(this.pendingScrubCommit.origin.fraction.toFixed(6))
                            : null,
                    });
                }
            } else if (this.pendingScrubCommit) {
                this._logPageScrub('pending-commit-awaiting-detail', {
                    reason: 'scrub-begin-no-descriptor',
                });
            }
        }
        const baselineDescriptor = this._cloneDescriptor(originDescriptor)
            || this._cloneDescriptor(this.currentLocationDescriptor)
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
        this._logPageScrub('begin', {
            originFraction,
            hasDescriptor: !!baselineDescriptor,
        });
        this._logJumpDiagnostic('scrub-begin', {
            hasOrigin: !!originDescriptor,
            backDepth: this.relocateStacks.back.length,
        });
        this._updateRelocateButtons();
    }

    endProgressScrubSession(finalDescriptor, { cancel, releaseFraction } = {}) {
        if (!this.scrubSession) return;
        const session = this.scrubSession;
        const comparisonDescriptor = this._cloneDescriptor(finalDescriptor ?? this.currentLocationDescriptor);
        let committed = false;
        let returnedToOrigin = false;
        let deferredCommit = false;
        const releaseValue = typeof releaseFraction === 'number' ? releaseFraction : (comparisonDescriptor?.fraction ?? null);
        const releaseMoved = typeof releaseValue === 'number'
            && typeof session.originFraction === 'number'
            && Math.abs(releaseValue - session.originFraction) > FRACTION_EPSILON;
        if (!cancel && session.originDescriptor && session.hasMoved && releaseMoved) {
            this.pendingScrubCommit = {
                origin: this._cloneDescriptor(session.originDescriptor),
                reason: 'scrub-release',
                releaseFraction: releaseValue,
                scheduledAt: Date.now(),
                releaseDescriptor: comparisonDescriptor,
            };
            deferredCommit = true;
            this._logPageScrub('pending-commit', {
                originFraction: session.originFraction ?? null,
                releaseFraction: releaseValue,
            });
        } else {
            this.pendingScrubCommit = null;
            if (!cancel) {
                returnedToOrigin = !session.hasMoved || !releaseMoved;
            }
        }
        const releaseDescriptor = this._descriptorFromFraction(releaseValue) || comparisonDescriptor;
        if (this.pendingScrubCommit && releaseDescriptor) {
            const pushedNow = this._maybeCommitPendingScrub({
                reason: 'scrub-finalize',
                liveScrollPhase: 'settled',
            }, releaseDescriptor, { updateButtons: false });
            if (pushedNow) {
                committed = true;
                deferredCommit = false;
                this._updateRelocateButtons();
            } else {
                deferredCommit = !!this.pendingScrubCommit;
            }
        } else {
            deferredCommit = !!this.pendingScrubCommit;
        }
        this._logPageScrub('end', {
            cancel,
            committed,
            returnedToOrigin,
            deferredCommit,
        });
        this.scrubSession = null;
        this._updateRelocateButtons();
        if (comparisonDescriptor || this.currentLocationDescriptor) {
            this._updatePrimaryLine(comparisonDescriptor || this.currentLocationDescriptor);
        }
        this._logJumpDiagnostic('scrub-end', {
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
        this._updateRendererSnapshotFromDetail(detail);
        await this._refreshRendererSnapshot();
        this.lastRelocateDetail = detail;
        this._handleRelocateHistory(detail);
        this._logJumpBack('relocate-detail', {
            reason: detail?.reason ?? null,
            phase: detail?.liveScrollPhase ?? null,
            fraction: typeof detail?.fraction === 'number' ? Number(detail.fraction.toFixed(6)) : null,
            processingPending: this.isProcessingRelocateJump,
        });
        this._logRelocateDetail(detail);
        this._updatePrimaryLine(detail);
        this._toggleCompletionStack();
        await this._updateSectionProgress({ refreshSnapshot: false });
        this._updateRelocateButtons();
        this._pruneBackStackIfReturnedToOrigin(detail);
        this._logPageNumberDiagnostic('relocate', {
            reason: detail?.reason ?? null,
            liveScrollPhase: detail?.liveScrollPhase ?? null,
            fraction: typeof detail?.fraction === 'number' ? detail.fraction : null,
            label: this.latestPrimaryLabel ?? '',
            ...(this.lastPrimaryLabelDiagnostics ?? {}),
        });
    }

    _updateRendererSnapshotFromDetail(detail) {
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
            this._updateFallbackTotalPages(normalized.total);
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
    
    _updatePrimaryLine(detail) {
        const fullLabelTarget = this.navPrimaryTextFull ?? this.navPrimaryText;
        const compactLabelTarget = this.navPrimaryTextCompact ?? this.navPrimaryText;
        const overlayLabelTarget = this.navHiddenOverlay?.text;
        if (!fullLabelTarget || !compactLabelTarget) return;

        // Ensure our label variant reflects the current hidden state (body/nav classes or flags).
        this._syncLabelVariantFromDOM();

        const scrubFrozenLabel = this.scrubSession?.active ? this.scrubSession.frozenLabel : null;
        const fullLabelCandidate = this.formatPrimaryLabel(detail, { allowRendererFallback: false });
        const rawLabel = fullLabelCandidate || scrubFrozenLabel || '';
        const normalizedRaw = rawLabel ? rawLabel.replace(/^Page\\s+/i, 'Page ') : '';
        const condensed = normalizedRaw ? this._condensePrimaryLabel(normalizedRaw) : '';

        // Full shows the complete page string (with total when available); compact omits the total.
        fullLabelTarget.textContent = normalizedRaw || condensed;
        compactLabelTarget.textContent = condensed || normalizedRaw;
        if (overlayLabelTarget) {
            overlayLabelTarget.textContent = condensed || normalizedRaw;
        }

        if (fullLabelCandidate) {
            this.latestPrimaryLabel = fullLabelCandidate;
        }

        this._updateCompactPercent(detail);

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

    _applyLabelVariant() {
        if (!this.navPrimaryText?.dataset) return;
        const hide = this.hideNavigationDueToScroll || this.navHidden;
        this.navPrimaryText.dataset.labelVariant = hide ? 'compact' : 'full';
    }

    _syncLabelVariantFromDOM() {
        const bodyHidden = typeof document !== 'undefined'
            ? document.body?.classList?.contains?.('nav-hidden')
            : false;
        const barHidden = this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? false;
        const desiredHide = bodyHidden || barHidden || this.hideNavigationDueToScroll || this.navHidden;
        if (this.navPrimaryText?.dataset) {
            const next = desiredHide ? 'compact' : 'full';
            if (this.navPrimaryText.dataset.labelVariant !== next) {
                this.navPrimaryText.dataset.labelVariant = next;
            }
        }
    }

    _updateCompactPercent(detail) {
        if (!this.navPrimaryPercent) return;
        const isCompact = this.navPrimaryText?.dataset?.labelVariant === 'compact';
        const fraction = this._fractionForPercent(detail);
        const hasValue = isCompact && typeof fraction === 'number' && isFinite(fraction);
        const primary = this.navPrimaryPercent;
        const overlay = this.navHiddenOverlay?.percent;

        if (hasValue) {
            const clamped = Math.max(0, Math.min(1, fraction));
            const text = this.formatPercent(clamped);
            primary.textContent = text;
            primary.hidden = false;
            primary.setAttribute('aria-hidden', 'false');
            if (overlay) {
                overlay.textContent = text;
                overlay.hidden = false;
                overlay.setAttribute('aria-hidden', 'false');
            }
        } else {
            primary.textContent = '';
            primary.hidden = true;
            primary.setAttribute('aria-hidden', 'true');
            if (overlay) {
                overlay.textContent = '';
                overlay.hidden = true;
                overlay.setAttribute('aria-hidden', 'true');
            }
        }
    }

    _fractionForPercent(detail) {
        if (detail && typeof detail.fraction === 'number') return detail.fraction;
        if (typeof this.lastScrubberFraction === 'number') return this.lastScrubberFraction;
        const descriptorFraction = typeof this.currentLocationDescriptor?.fraction === 'number'
            ? this.currentLocationDescriptor.fraction
            : null;
        return descriptorFraction;
    }

    refreshAuxiliaryLayout() {
        this._updateAuxiliaryInsets();
    }

    _applyRelocateButtonEdges() {
        const backEdge = this.isRTL ? 'right' : 'left';
        const forwardEdge = this.isRTL ? 'left' : 'right';
        this._setButtonEdge(this.navRelocateButtons?.back, backEdge);
        this._setButtonEdge(this.navRelocateButtons?.forward, forwardEdge);
        this._updateAuxiliaryInsets();
    }

    _updateAuxiliaryInsets() {
        const styleTarget = document.body ?? document.documentElement;
        if (!styleTarget?.style) return;
        const trackSide = this.isRTL ? 'left' : 'right';
        const trackingVisible =
            !!this.pageTrackingContainer
            && !this.pageTrackingContainer.hidden
            && this.pageTrackingContainer.offsetWidth > 0
            && !!this.pageTrackingButtons
            && !this.pageTrackingButtons.hidden
            && this.pageTrackingButtons.childElementCount > 0;
        const reserve = trackingVisible
            ? this.pageTrackingContainer.offsetWidth + 8
            : 0;
        const leftInset = trackSide === 'left' ? reserve : 0;
        const rightInset = trackSide === 'right' ? reserve : 0;
        styleTarget.style.setProperty('--nav-left-aux-inset', `${leftInset}px`);
        styleTarget.style.setProperty('--nav-right-aux-inset', `${rightInset}px`);
    }

    _setButtonEdge(button, edge) {
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

    _descriptorForRelocateLabel(direction) {
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
        const derived = this._derivePrimaryLabel(detail);
        if (derived) {
            const label = condensedOnly ? this._condensePrimaryLabel(derived) : derived;
            if (!condensedOnly) {
                this.latestPrimaryLabel = label;
            }
            return label;
        }
        // No fallback beyond the derived page metrics.
        return '';
    }

    getPrimaryDisplayLabel(detail) {
        const label = this.formatPrimaryLabel(detail, { allowRendererFallback: false });
        return label ?? '';
    }

    getPageEstimate(detail) {
        const metrics = this._computePageMetrics(detail);
        if (!metrics) return null;
        const current = typeof metrics.currentPageNumber === 'number' ? metrics.currentPageNumber : null;
        const total = typeof metrics.totalPages === 'number' ? metrics.totalPages : null;
        if (current == null && total == null) return null;
        return { current, total };
    }

    getLocationTotalHint() {
        return this.lastKnownLocationTotal
            ?? this.lastPrimaryLabelDiagnostics?.locationTotal
            ?? null;
    }

    getScrubberFraction(detail = null) {
        if (detail) {
            const metrics = this._computePageMetrics(detail);
            const computed = this.lastScrubberFraction
                ?? this._scrubberFractionFromMetrics({
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

    _scrubberFractionFromMetrics({ current, total, fallbackFraction }) {
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

    _derivePrimaryLabel(detail) {
        if (!detail) {
            this.lastPrimaryLabelDiagnostics = {
                source: 'no-detail',
                label: '',
                totalPageCount: this.totalPageCount,
            };
            return null;
        }

        const metrics = this._computePageMetrics(detail);
        if (metrics?.currentPageNumber != null) {
            const currentPageNumber = metrics.currentPageNumber;
            const totalPages = metrics.totalPages;
            const label = totalPages != null
                ? `Page ${currentPageNumber} of ${totalPages}`
                : `Page ${currentPageNumber}`;
            this.lastPrimaryLabelDiagnostics = {
                source: 'page-metrics',
                label,
                currentPageNumber,
                totalPages,
                totalPageCount: this.totalPageCount,
            };
            this.latestPrimaryLabel = label;
            return label;
        }

        // If no page metrics are available yet, we won't show a label.
        this.latestPrimaryLabel = '';
        this.lastPrimaryLabelDiagnostics = {
            source: 'no-page-metrics',
            label: '',
            totalPageCount: this.totalPageCount,
        };
        return null;
    }

    _condensePrimaryLabel(label) {
        if (typeof label !== 'string') return '';
        // Prefer an explicit "Page <n>" capture so we keep the prefix even if the suffix format changes.
        const pageMatch = label.match(/\bPage\s*(\d+)/i);
        if (pageMatch) {
            return `Page ${pageMatch[1]}`.replace(/\s+/g, ' ').trim();
        }
        // Otherwise strip any "of <total>" suffix (allowing for varied whitespace/non-breaking spaces).
        const trimmed = label.replace(/\s*of\s+.*$/i, '').trim();
        return trimmed || label;
    }

    _computePageMetrics(detail) {
        if (!detail) return null;
        const fraction = typeof detail.fraction === 'number' ? detail.fraction : null;
        const pageItem = detail.pageItem ?? null;
        const pageItemLabel = typeof pageItem?.label === 'string' ? pageItem.label : null;
        const pageItemKey = pageItem ? ensurePageKey(pageItem) : null;
        const pageIndex = this._resolvePageIndex(pageItem);
        const sectionIndex = typeof detail.sectionIndex === 'number'
            ? detail.sectionIndex
            : (typeof detail.index === 'number' ? detail.index : null);
        const locationCurrent = typeof detail.location?.current === 'number' ? detail.location.current : null;
        const locationTotal = typeof detail.location?.total === 'number' ? detail.location.total : null;
        const detailPageNumber = typeof detail.pageNumber === 'number' ? detail.pageNumber : null;
        const detailPageCount = typeof detail.pageCount === 'number' ? detail.pageCount : null;
        const totalPagesRaw = this._currentTotalPages(detail, detailPageCount);
        const approxIndexFromFraction = this._pageIndexFromFraction(fraction, detailPageCount ?? totalPagesRaw);
        const locationIndex = locationCurrent != null ? locationCurrent : null;
        const rendererIndex = this._rendererSnapshotIndex();
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
        const sectionOffset = sectionIndex != null ? this._sectionOffset(sectionIndex) : 0;
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
        const scrubFraction = this._scrubberFractionFromMetrics({
            current: adjustedCurrent,
            total: adjustedTotal,
            fallbackFraction: fraction,
        });
        if (scrubFraction != null) {
            this.lastScrubberFraction = scrubFraction;
        }
        this._logPageMetrics({
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
    
    _toggleCompletionStack(forceShow) {
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
            this.navSectionProgress?.leading,
            this.navSectionProgress?.trailing,
            this.navSectionProgress?.center,
            this.navPrimaryText,
            this.navPrimaryPercent,
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
        if (this.navPrimaryPercent) {
            if (shouldShow) {
                this.navPrimaryPercent.hidden = true;
                this.navPrimaryPercent.setAttribute('aria-hidden', 'true');
            } else {
                const descriptor = this.lastRelocateDetail || this.currentLocationDescriptor;
                this._updateCompactPercent(descriptor);
            }
        }
    }

    async _updateSectionProgress({ refreshSnapshot = true } = {}) {
        const leading = this.navSectionProgress?.leading;
        const trailing = this.navSectionProgress?.trailing;
        const center = this.navSectionProgress?.center;
        if (leading) leading.hidden = true;
        if (trailing) trailing.hidden = true;
        if (center) center.hidden = true;
        try {
            const pagesLeft = await this._calculatePagesLeftInSection({ refreshSnapshot });
            const showingCompletion = this.navContext?.showingFinish || this.navContext?.showingRestart;
            if (this.hideNavigationDueToScroll || showingCompletion) return;
            if (!pagesLeft || pagesLeft <= 0) return;
            if (!center) return;
            const label = pagesLeft === 1
                ? '1 page left in chapter'
                : `${pagesLeft} pages left in chapter`;
            center.textContent = label;
            center.hidden = false;
            logEBookPageNumLimited('ui:section-progress', {
                label,
                pagesLeft,
                target: 'center',
                rendererCurrent: this.rendererPageSnapshot?.current ?? null,
                rendererTotal: this.rendererPageSnapshot?.total ?? null,
                hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            });
        } catch (error) {
            console.error('Failed to update section progress', error);
        }
    }

    
    async _calculatePagesLeftInSection({ refreshSnapshot = true } = {}) {
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
            await this._refreshRendererSnapshot();
        }
        if (!this.rendererPageSnapshot || !this.rendererPageSnapshot.total || this.rendererPageSnapshot.total <= 0) return null;
        return Math.max(0, this.rendererPageSnapshot.total - this.rendererPageSnapshot.current);
    }
    
    _handleRelocateHistory(detail) {
        const descriptor = this._makeLocationDescriptor(detail);
        if (!descriptor) return;
        const lastOrigin = this.scrubSession?.originDescriptor;
        // If the relocate matches the scrub origin immediately after a jump, don't clobber history yet.
        if (this.scrubSession?.pendingCommit && lastOrigin && this._isSameDescriptor(lastOrigin, descriptor)) {
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
            this._finalizePendingRelocateJump(descriptor);
            if (this.isProcessingRelocateJump || this.pendingRelocateJump) {
                this._logJumpBack('relocate-finalize-pending', {
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
        let descriptorChanged = previousDescriptor && !this._isSameDescriptor(previousDescriptor, descriptor);
        const isScrubbing = !!this.scrubSession?.active;
        const originDescriptor = this.scrubSession?.originDescriptor;
        const originFraction = typeof this.scrubSession?.originFraction === 'number' ? this.scrubSession.originFraction : null;
        const detailFraction = typeof detail?.fraction === 'number' ? detail.fraction : null;
        const fractionMoved = originFraction != null && detailFraction != null && Math.abs(detailFraction - originFraction) > FRACTION_EPSILON;
        const descriptorDiffersFromOrigin = !!(isScrubbing && originDescriptor && descriptor && !this._isSameDescriptor(originDescriptor, descriptor));
        const movedFromOrigin = isScrubbing && (fractionMoved || descriptorDiffersFromOrigin);
        if (!descriptorChanged && movedFromOrigin && previousDescriptor && descriptor) {
            descriptorChanged = true;
        }
        if (isScrubbing) {
            this._trackScrubMovement({ descriptor, movedFromOrigin, detailFraction });
        }
        if (isJumpReason && descriptorChanged && !isLiveScrollReason) {
            if (!isScrubbing && previousDescriptor) {
                this._pushBackStack(previousDescriptor);
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
            this._pushBackStack(previousDescriptor);
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
            this._logStackSnapshot('forward-clear');
        }
        this._logJumpDiagnostic('relocate-history', {
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
        this._maybeCommitPendingScrub(detail, descriptor);
    }

    _trackScrubMovement({ descriptor, movedFromOrigin, detailFraction }) {
        const session = this.scrubSession;
        if (!session || !session.active) return;
        if (!session.originDescriptor && descriptor) {
            session.originDescriptor = this._cloneDescriptor(descriptor);
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
            this._logPageScrub('update', {
                fraction: previewFraction,
                originFraction: session.originFraction ?? null,
                movedFromOrigin,
            });
        }
    }

    _pushBackStack(descriptor, { stripCFI = false } = {}) {
        if (!descriptor) return null;
        const entry = this._cloneDescriptor(descriptor);
        if (!entry) return null;
        if (stripCFI) {
            entry.cfi = null;
        }
        const backStack = this.relocateStacks.back;
        backStack.push(entry);
        const index = backStack.length - 1;
        if (backStack.length > MAX_RELOCATE_STACK) {
            backStack.shift();
            this._logPageScrub('pop', { index: 0, reason: 'truncate' });
        }
        this.relocateStacks.forward.length = 0;
        this._logPageScrub('stack', {
            action: 'push',
            index,
            fraction: entry.fraction ?? null,
        });
        this._logJumpDiagnostic('relocate-stack-push', {
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
        this._logStackSnapshot('push');
        return { entry, index };
    }
    
    _makeLocationDescriptor(detail) {
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

    _descriptorFromFraction(fraction) {
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

    _cloneDescriptor(descriptor) {
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
    
    _requestRendererPrimaryLine() {
        // No-op: we no longer backfill the primary label with renderer page numbers.
        return;
    }
    
    _normalizeRendererPageInfo(rawPage, rawTotal, renderer) {
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
    
    _formatRendererPageLabel(info) {
        if (!info) return '';
        if (info.total && info.total > 0) {
            return `${info.current} of ${info.total}`;
        }
        return '';
    }

    async _refreshRendererSnapshot() {
        const renderer = this.getRenderer?.();
        if (!renderer || typeof renderer.page !== 'function' || typeof renderer.pages !== 'function') {
            return null;
        }
        try {
            const [pageResult, pagesResult] = await Promise.allSettled([renderer.page(), renderer.pages()]);
            if (pageResult.status !== 'fulfilled' || pagesResult.status !== 'fulfilled') {
                return null;
            }
            const normalized = this._normalizeRendererPageInfo(pageResult.value, pagesResult.value, renderer);
            if (!normalized) return null;
            this.rendererPageSnapshot = normalized;
            this._updateFallbackTotalPages(normalized.total);
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
            this._logPageNumberDiagnostic('renderer-snapshot', {
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

    _logPageNumberDiagnostic(event, payload = {}) {
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

    _logPageScrub(_event, _payload = {}) {}

    _logJumpDiagnostic(event, payload = {}) {
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

    _isSameDescriptor(a, b) {
        if (!a || !b) return false;
        if (a.cfi && b.cfi) return a.cfi === b.cfi;
        if (typeof a.fraction === 'number' && typeof b.fraction === 'number') {
            return Math.abs(a.fraction - b.fraction) < FRACTION_EPSILON;
        }
        return false;
    }
    
    _resolvePageIndex(pageItem) {
        if (!pageItem || !this.pageTargetIndexByKey) return null;
        const key = ensurePageKey(pageItem);
        if (!key) return null;
        return this.pageTargetIndexByKey.get(key) ?? null;
    }
    
    _pageIndexFromFraction(fraction, totalOverride) {
        const total = typeof totalOverride === 'number' && totalOverride > 0
            ? totalOverride
            : (this.totalPageCount > 0 ? this.totalPageCount : null);
        if (typeof fraction !== 'number' || !total) return null;
        const approx = Math.floor(fraction * total);
        return Math.max(0, Math.min(total - 1, approx));
    }

    _sanitizePageLabel(label) {
        if (typeof label !== 'string') return '';
        const trimmed = label.trim();
        if (!trimmed) return '';
        if (trimmed.toLowerCase().startsWith('page ')) {
            const remainder = trimmed.slice(5).trim();
            if (remainder) return remainder;
        }
        return trimmed;
    }

    _pageNumberFromLabel(label) {
        if (typeof label !== 'string') return '';
        const match = label.match(/(\d+)/);
        if (!match) return '';
        const normalized = match[1]?.replace(/^0+/, '') ?? '';
        return normalized || '0';
    }

    _rendererSnapshotIndex() {
        const scrolled = this.rendererPageSnapshot?.scrolled;
        if (scrolled !== false) return null; // only trust renderer index in paginated mode
        const current = this.rendererPageSnapshot?.current;
        if (typeof current !== 'number') return null;
        return Math.max(0, current - 1);
    }

    _sectionOffset(sectionIndex) {
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

    _hasCompleteSectionCounts() {
        if (!this.linearSectionCount || this.linearSectionCount <= 0) return false;
        let filled = 0;
        for (const idx of this.linearSectionIndexes) {
            if (this.sectionPageCounts.has(idx)) filled += 1;
        }
        return filled === this.linearSectionCount;
    }

    _currentTotalPages(detail, detailPageCount) {
        const candidates = [];
        if (this.totalPageCount > 0) {
            candidates.push({ source: 'page-targets', total: this.totalPageCount });
        }
        if (this.sectionPageCounts.size > 0 && this._hasCompleteSectionCounts()) {
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
        const locationCandidate = candidates.find(candidate => candidate.source === 'location') ?? null;
        const pageBasedPrecedence = ['page-targets', 'sections', 'renderer', 'detail', 'fallback'];
        const bestPageBased = candidates
            .filter(candidate => candidate.source !== 'location')
            .sort((a, b) => {
                const pa = pageBasedPrecedence.indexOf(a.source);
                const pb = pageBasedPrecedence.indexOf(b.source);
                if (pa !== pb) return pa - pb;
                return (b.total ?? 0) - (a.total ?? 0);
            })[0] ?? null;

        let best = bestPageBased ?? locationCandidate;
        const hasStructuredTotals = this.totalPageCount > 0 || this._hasCompleteSectionCounts();
        const locationClearlyBeatsWeakPageTotals =
            !!locationCandidate
            && locationCandidate.total > 1
            && (
                !bestPageBased
                || bestPageBased.total <= 1
                || (
                    !hasStructuredTotals
                    && bestPageBased.source === 'fallback'
                    && locationCandidate.total > bestPageBased.total
                )
            );
        if (locationClearlyBeatsWeakPageTotals) {
            best = locationCandidate;
        }
        this.lastTotalSource = best?.source ?? null;
        if (best?.total && best.source !== 'page-targets') {
            this._updateFallbackTotalPages(best.total);
        }
        logBug('total-pages-choice', {
            chosenSource: best?.source ?? null,
            chosenTotal: best?.total ?? null,
            candidates: candidates.map(({ source, total }) => ({ source, total })),
            sectionsComplete: this._hasCompleteSectionCounts(),
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

    _logPageMetrics(payload) {
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

    _updateFallbackTotalPages(total) {
        if (typeof total !== 'number' || total <= 0) return;
        if (!this.fallbackTotalPageCount || total > this.fallbackTotalPageCount) {
            this.fallbackTotalPageCount = total;
        }
    }

    // Public wrapper so external callers (e.g., scrubber live updates) can format labels without accessing private fields.
    labelForDescriptor(descriptor) {
        return this._labelForDescriptor(descriptor);
    }

    _labelForDescriptor(descriptor) {
        if (!descriptor) return '';
        const derivedTotal = this.lastPrimaryLabelDiagnostics?.totalPages
            ?? this.lastPageMetricsSnapshot?.totalPages
            ?? this.fallbackTotalPageCount
            ?? (this.totalPageCount > 0 ? this.totalPageCount : null);
        if (typeof descriptor.fraction === 'number' && derivedTotal && derivedTotal > 0) {
            const clampedTotal = Math.max(1, derivedTotal);
            const idx = Math.round(Math.max(0, Math.min(1, descriptor.fraction)) * (clampedTotal - 1));
            return `${idx + 1}`;
        }
        const currentPageNumber = this.lastPrimaryLabelDiagnostics?.currentPageNumber
            ?? this.lastPageMetricsSnapshot?.currentPageNumber
            ?? null;
        if (typeof currentPageNumber === 'number' && currentPageNumber > 0) {
            return `${currentPageNumber}`;
        }
        // No page info; leave label empty.
        return '';
    }
    
    _isRelocateButtonVisible(direction) {
        if (!direction) return false;
        const button = this.navRelocateButtons?.[direction];
        return !!(button && !button.hidden && !button.disabled);
    }

    _updateRelocateButtons() {
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
        const backLabelDescriptor = this._descriptorForRelocateLabel('back');
        const forwardLabelDescriptor = this._descriptorForRelocateLabel('forward');
        if (this.navRelocateLabels?.back) {
            this.navRelocateLabels.back.textContent = showBack ? this._labelForDescriptor(backLabelDescriptor) : '';
        }
        if (this.navRelocateLabels?.forward) {
            this.navRelocateLabels.forward.textContent = showForward ? this._labelForDescriptor(forwardLabelDescriptor) : '';
        }
        this._updateSectionProgress();
        if (this.previousRelocateVisibility.back !== showBack) {
            this.previousRelocateVisibility.back = showBack;
            this._logJumpDiagnostic('relocate-visibility', {
                direction: 'back',
                visible: showBack,
                backDepth: backStack.length,
                hiddenDueToScroll: this.hideNavigationDueToScroll,
            });
        }
        if (this.previousRelocateVisibility.forward !== showForward) {
            this.previousRelocateVisibility.forward = showForward;
            this._logJumpDiagnostic('relocate-visibility', {
                direction: 'forward',
                visible: showForward,
                forwardDepth: forwardStack.length,
                hiddenDueToScroll: this.hideNavigationDueToScroll,
            });
        }
        this._updateAuxiliaryInsets();
    }
    
    _serializeStack(stack) {
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

    _logStackSnapshot(reason, extra = {}) {
        this._logJumpDiagnostic('relocate-stack-snapshot', {
            reason,
            backDepth: this.relocateStacks?.back?.length ?? 0,
            forwardDepth: this.relocateStacks?.forward?.length ?? 0,
            backStack: this._serializeStack(this.relocateStacks?.back),
            forwardStack: this._serializeStack(this.relocateStacks?.forward),
            scrubActive: !!this.scrubSession?.active,
            pendingCommit: !!this.pendingScrubCommit,
            ...extra,
        });
    }

    _logRelocateDetail(_detail) {}

    _pruneBackStackIfReturnedToOrigin(detail) {
        if (!detail) return;
        const descriptor = this._makeLocationDescriptor(detail);
        if (!descriptor) return;
        const reason = (detail.reason || '').toLowerCase();
        const isLiveScroll = reason === 'live-scroll';
        // Only prune when not actively scrubbing; keep history stable during live scroll sessions.
        const canPrune = !isLiveScroll && !this.scrubSession?.active;
        if (!canPrune) return;
        const backStack = this.relocateStacks.back;
        if (!backStack?.length) return;
        const lastEntry = backStack[backStack.length - 1];
        if (!lastEntry) return;
        if (!this._isSameDescriptor(lastEntry, descriptor)) {
            return;
        }
        backStack.pop();
        this._logPageScrub('pop', {
            index: backStack.length,
            reason: 'returned-to-origin-after-scrub',
            descriptorFraction: typeof descriptor.fraction === 'number' ? Number(descriptor.fraction.toFixed(6)) : null,
        });
        this._logStackSnapshot('returned-to-origin');
        this._updateRelocateButtons();
    }

    _maybeCommitPendingScrub(detail, descriptor, { updateButtons = true } = {}) {
        if (!this.pendingScrubCommit) return false;
        const { origin, reason, scheduledAt, releaseDescriptor, releaseFraction } = this.pendingScrubCommit;
        const phase = detail?.liveScrollPhase ?? null;
        const canCommit = !detail || detail.reason !== 'live-scroll' || phase === 'settled';
        if (!canCommit) return false;
        let effectiveDescriptor = descriptor || releaseDescriptor || null;
        if (!origin || !effectiveDescriptor) {
            this.pendingScrubCommit = null;
            this._logPageScrub('pending-commit-skipped', {
                reason: 'missing-descriptor',
                releaseReason: reason ?? null,
            });
            return false;
        }
        const shouldSkipForOrigin = this._isSameDescriptor(origin, effectiveDescriptor)
            && !(typeof releaseFraction === 'number' && typeof origin.fraction === 'number' && Math.abs(releaseFraction - origin.fraction) > FRACTION_EPSILON);
        if (shouldSkipForOrigin) {
            this.pendingScrubCommit = null;
            this._logPageScrub('pending-commit-skipped', {
                reason: 'returned-to-origin',
                releaseReason: reason ?? null,
                descriptorFraction: typeof effectiveDescriptor?.fraction === 'number' ? Number(effectiveDescriptor.fraction.toFixed(6)) : null,
            });
            return false;
        }
        const result = this._pushBackStack(origin, { stripCFI: true });
        if (result?.entry) {
            this._logPageScrub('push', {
                index: result.index,
                fraction: result.entry?.fraction ?? null,
                reason: reason ?? 'pending-commit',
                commitPhase: phase ?? null,
                elapsedMs: scheduledAt ? Date.now() - scheduledAt : null,
                stackDepth: this.relocateStacks?.back?.length ?? null,
            });
            this._logStackSnapshot('pending-commit', {
                commitReason: reason ?? 'pending-commit',
            });
        }
        this.pendingScrubCommit = null;
        if (updateButtons) {
            this._updateRelocateButtons();
        }
        return !!result?.entry;
    }
    
    _finalizePendingRelocateJump(descriptor) {
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
            const entry = this._cloneDescriptor(pending.preJumpDescriptor);
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
        this._logJumpBack('jump-finalized', {
            direction,
            targetFraction,
            backDepth: this.relocateStacks?.back?.length ?? 0,
            forwardDepth: this.relocateStacks?.forward?.length ?? 0,
        });
        this._logStackSnapshot('jump-finalized', {
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
        this._updateRelocateButtons();
    }
    
    async _handleRelocateJump(direction) {
        this._logJumpButton('tap', {
            direction,
            backDepth: this.relocateStacks?.back?.length ?? 0,
            forwardDepth: this.relocateStacks?.forward?.length ?? 0,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            navHiddenClass: this.navBar?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            isProcessingRelocateJump: !!this.isProcessingRelocateJump,
        });

        const stack = this.relocateStacks?.[direction];
        if (!stack?.length) {
            this._logJumpBack('tap-ignored-empty', { direction });
            this._logJumpButton('tap-ignored-empty', { direction });
            logBug('EBOOKJUMP', { event: 'tap-empty', direction });
            return;
        }
        if (this.hideNavigationDueToScroll) {
            this._logJumpBack('tap-ignored-hidden', { direction });
            this._logJumpButton('tap-ignored-hidden', { direction });
            logBug('EBOOKJUMP', { event: 'tap-hidden', direction });
            return;
        }
        if (this.pendingRelocateJump) {
            this._logJumpBack('tap-ignored-pending', { direction });
            this._logJumpButton('tap-ignored-pending', { direction });
            return;
        }
        const descriptor = this._cloneDescriptor(stack[stack.length - 1]);
        if (!descriptor) {
            this._logJumpBack('tap-ignored-nodescriptor', { direction });
            this._logJumpButton('tap-ignored-nodescriptor', { direction });
            return;
        }

        const preJumpDescriptor = this.lastRelocateDetail
            ? this._makeLocationDescriptor(this.lastRelocateDetail)
            : this._cloneDescriptor(this.currentLocationDescriptor);
        const opposite = direction === 'back' ? 'forward' : 'back';
        const oppositeStack = this.relocateStacks?.[opposite];

        this.pendingRelocateJump = {
            direction,
            targetDescriptor: descriptor,
            preJumpDescriptor,
        };
        this.isProcessingRelocateJump = true;
        this._updateRelocateButtons();

        const targetFraction = typeof descriptor?.fraction === 'number' ? Number(descriptor.fraction.toFixed(6)) : null;
        this._logJumpBack('tap', {
            direction,
            stackDepth: stack.length,
            targetFraction,
            oppositeDepth: oppositeStack?.length ?? 0,
            hiddenDueToScroll: this.hideNavigationDueToScroll,
        });
        this._logJumpButton('tap-valid', {
            direction,
            stackDepth: stack.length,
            targetFraction,
            oppositeDepth: oppositeStack?.length ?? 0,
            hiddenDueToScroll: this.hideNavigationDueToScroll,
        });
        this._logJumpDiagnostic('relocate-button', {
            direction,
            stackDepth: stack.length,
            hiddenDueToScroll: this.hideNavigationDueToScroll,
            targetFraction,
            oppositeDepth: oppositeStack?.length ?? 0,
        });
        this._logStackSnapshot('button-prejump', {
            direction,
            targetFraction,
        });

        try {
            this._logJumpBack('request', {
                direction,
                targetFraction,
                stackDepth: stack.length,
            });
            this._logJumpButton('request', {
                direction,
                targetFraction,
                stackDepth: stack.length,
            });

            await this.onJumpRequest?.(descriptor);

            this._logJumpBack('request-complete', {
                direction,
                targetFraction,
            });
            this._logJumpButton('request-complete', {
                direction,
                targetFraction,
            });
        } catch (error) {
            console.error('Failed to navigate to saved location', error);
            this._logJumpBack('error', {
                direction,
                message: error?.message ?? String(error),
            });
            this._logJumpButton('error', {
                direction,
                message: error?.message ?? String(error),
            });
            this.pendingRelocateJump = null;
            this.isProcessingRelocateJump = false;
            this._logStackSnapshot('button-error', { direction });
            this._updateRelocateButtons();
        } finally {
            this._logJumpBack('postjump', {
                direction,
                pending: !!this.pendingRelocateJump,
                processing: !!this.isProcessingRelocateJump,
            });
            this._logJumpButton('postjump', {
                direction,
                pending: !!this.pendingRelocateJump,
                processing: !!this.isProcessingRelocateJump,
            });
            this._logStackSnapshot('button-postjump', { direction });
        }
    }
}
