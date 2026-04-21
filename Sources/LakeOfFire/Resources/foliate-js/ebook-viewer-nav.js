const MAX_RELOCATE_STACK = 50;
const FRACTION_EPSILON = 0.000001;

// Focused pagination/bake diagnostics (capped to avoid spam)
let logEBookPageNumCounter = 0;
const LOG_EBOOK_PAGE_NUM_LIMIT = 400;
const MANABI_NAV_SENTINEL_ADJUST_ENABLED = true;
const NAV_PAGE_NUM_WHITELIST = new Set([
    'nav:set-page-targets',
    'nav:total-pages-source',
    'nav:total-pages-gate',
    'nav:section-counts-state',
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
    const line = `# PAGENUM ${JSON.stringify(payload)}`;
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

const logEPUBNav = (event, detail = {}) => {
    const payload = { event, ...detail };
    const line = `# PAGENUM ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
        try { console.log(line); } catch (_) {}
    }
};

const normalizeSpineHrefForPageNum = (href) => {
    if (typeof href !== 'string') return null;
    const trimmed = href.trim();
    if (!trimmed) return null;
    const hashIndex = trimmed.indexOf('#');
    return hashIndex >= 0 ? trimmed.slice(0, hashIndex) : trimmed;
};

const getPrimaryRendererContent = (renderer) => {
    try {
        const contents = renderer?.getContents?.();
        return Array.isArray(contents) && contents.length > 0 ? contents[0] ?? null : null;
    } catch (_error) {
        return null;
    }
};

const getRendererContentHref = (renderer) => {
    const content = getPrimaryRendererContent(renderer);
    const datasetHref = content?.doc?.body?.dataset?.manabiSourceHref;
    if (typeof datasetHref === 'string' && datasetHref.trim()) {
        return datasetHref;
    }
    const locationHref = content?.doc?.location?.href;
    if (typeof locationHref !== 'string' || !locationHref.trim()) return null;
    try {
        const url = new URL(locationHref);
        const subpath = url.searchParams.get('subpath');
        return subpath && subpath.trim() ? subpath : null;
    } catch (_error) {
        return null;
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
        this.sectionIndexByHref = new Map();
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
        this.lastTotalPagesGateSnapshot = null;
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
    pageTargetSectionPageCounts = new Map();
    pageTargetSectionOffsets = new Map();

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
        const isPartial = typeof linearCount === 'number' && linearCount > 0 && counts.size < linearCount;
        this._logPageNumberDiagnostic('cachewarmer.section-counts.apply', {
            receivedCount: counts.size,
            linearCount,
            isPartial,
            receivedTotal: Array.from(counts.values()).reduce((a, v) => a + (Number.isFinite(v) ? v : 0), 0),
            sectionCountsPreview: Array.from(counts.entries()).slice(0, 8).map(([index, count]) => ({ index, count })),
        });
        logBug?.('pagecount:cachewarmer:apply', {
            received: counts.size,
            linearCount,
            isPartial,
            total: Array.from(counts.values()).reduce((a, v) => a + (Number.isFinite(v) ? v : 0), 0),
        });
        counts.forEach((count, index) => {
            if (typeof count === 'number' && count > 0 && Number.isInteger(index) && index >= 0) {
                this.sectionPageCounts.set(index, count);
            }
        });
        const total = Array.from(counts.values()).reduce((acc, v) => acc + (Number.isFinite(v) && v > 0 ? v : 0), 0);
        if (total > 0 && !isPartial) {
            this.fallbackTotalPageCount = total;
            this.fallbackTotalPageCountSource = 'cachewarmer';
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
            this.fallbackTotalPageCountSource = 'page-targets';
        }
        this._rebuildPageTargetSectionMetrics();
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
        this.sectionIndexByHref = new Map();
        if (Array.isArray(this.navContext?.sections)) {
            this.navContext.sections.forEach((section, idx) => {
                if (section?.linear !== 'no') this.linearSectionIndexes.add(idx);
                const normalizedHref = normalizeSpineHrefForPageNum(section?.href ?? section?.id ?? null);
                if (normalizedHref) {
                    this.sectionIndexByHref.set(normalizedHref, idx);
                }
            });
        }
        logEPUBNav('nav.sections.received', {
            sectionCount: Array.isArray(this.navContext?.sections) ? this.navContext.sections.length : 0,
            linearSectionCount: this.linearSectionIndexes.size,
            sectionMapSize: this.sectionIndexByHref.size,
            preview: Array.isArray(this.navContext?.sections)
                ? this.navContext.sections.slice(0, 8).map((section, idx) => ({
                    index: idx,
                    href: section?.href ?? null,
                    normalizedHref: normalizeSpineHrefForPageNum(section?.href ?? section?.id ?? null),
                    linear: section?.linear ?? null,
                }))
                : [],
        });
        this.linearSectionCount = this.linearSectionIndexes.size || null;
        const cachedCounts = Array.isArray(globalThis.__manabiCacheWarmerSectionPageCounts)
            ? new Map(globalThis.__manabiCacheWarmerSectionPageCounts.filter(entry =>
                Array.isArray(entry)
                && entry.length >= 2
                && typeof entry[0] === 'number'
                && typeof entry[1] === 'number'
                && entry[1] > 0
            ))
            : null;
        if (cachedCounts?.size) {
            this._logPageNumberDiagnostic('cachewarmer.section-counts.handoff', {
                receivedCount: cachedCounts.size,
                linearCount: this.linearSectionCount,
                sectionCountsPreview: Array.from(cachedCounts.entries()).slice(0, 8).map(([index, count]) => ({ index, count })),
            });
            this.setSectionPageCountsFromCache(cachedCounts);
        }
        this._rebuildPageTargetSectionMetrics();
        if (this.lastRelocateDetail) {
            this._updateRendererSnapshotFromDetail(this.lastRelocateDetail);
            this._updatePrimaryLine(this.lastRelocateDetail);
        }
        this._toggleCompletionStack();
        this._updateSectionProgress();
        this._updateRelocateButtons();
    }
    
    setHideNavigationDueToScroll(shouldHide, source = 'unknown', context = null) {
        const previous = this.hideNavigationDueToScroll;
        this.hideNavigationDueToScroll = !!shouldHide;
        this.navBar?.classList.toggle('nav-hidden-due-to-scroll', this.hideNavigationDueToScroll);
        this._applyLabelVariant();
        logEPUBNav('nav.visibility.scroll-toggle', {
            source,
            previous,
            shouldHide: this.hideNavigationDueToScroll,
            navHidden: this.navHidden,
            labelVariant: this.navPrimaryText?.dataset?.labelVariant ?? null,
            navHiddenClass: this.navBar?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            primaryLabel: this.navPrimaryTextFull?.textContent || this.navPrimaryText?.textContent || '',
            compactLabel: this.navPrimaryTextCompact?.textContent || '',
            context,
        });
        logNavHide('hud:set-hide', {
            shouldHide: this.hideNavigationDueToScroll,
            previous,
            source,
            labelVariant: this.navPrimaryText?.dataset?.labelVariant ?? null,
            primaryLabel: this.navPrimaryTextFull?.textContent || this.navPrimaryText?.textContent || '',
            compactLabel: this.navPrimaryTextCompact?.textContent || '',
            hiddenOverlayLabel: this.navHiddenOverlay?.text?.textContent || '',
            hiddenOverlayPercent: this.navHiddenOverlay?.percent?.textContent || '',
            hiddenOverlayLabelWidth: this.navHiddenOverlay?.text?.offsetWidth ?? null,
            hiddenOverlayPercentWidth: this.navHiddenOverlay?.percent?.offsetWidth ?? null,
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
        const previous = this.navHidden;
        this.navHidden = !!shouldHide;
        this._applyLabelVariant();
        const descriptor = this.lastRelocateDetail || this.currentLocationDescriptor;
        if (descriptor) {
            this._updatePrimaryLine(descriptor);
        }
        logEPUBNav('nav.visibility.hidden-toggle', {
            previous,
            shouldHide: this.navHidden,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            labelVariant: this.navPrimaryText?.dataset?.labelVariant ?? null,
            navHiddenClass: this.navBar?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            primaryLabel: this.navPrimaryTextFull?.textContent || this.navPrimaryText?.textContent || '',
            compactLabel: this.navPrimaryTextCompact?.textContent || '',
        });
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
        const previousSectionIndex = typeof this.lastRelocateDetail?.sectionIndex === 'number'
            ? this.lastRelocateDetail.sectionIndex
            : (typeof this.lastRelocateDetail?.index === 'number' ? this.lastRelocateDetail.index : null);
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
        logEPUBNav('nav.visibility.relocate', {
            reason: detail?.reason ?? null,
            previousSectionIndex,
            nextSectionIndex: typeof detail.sectionIndex === 'number' ? detail.sectionIndex : null,
            sectionChanged: typeof previousSectionIndex === 'number' && typeof detail.sectionIndex === 'number'
                ? previousSectionIndex !== detail.sectionIndex
                : null,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            navHidden: this.navHidden,
            navHiddenClass: this.navBar?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            labelVariant: this.navPrimaryText?.dataset?.labelVariant ?? null,
        });
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
        const normalizedRaw = typeof rawLabel === 'string'
            ? rawLabel.replace(/\s+/g, ' ').trim()
            : '';
        const condensed = normalizedRaw ? this._condensePrimaryLabel(normalizedRaw) : '';

        // Full shows the current page and total; compact/hidden shows only the current page.
        fullLabelTarget.textContent = normalizedRaw || condensed;
        compactLabelTarget.textContent = condensed || normalizedRaw;
        if (overlayLabelTarget) {
            overlayLabelTarget.textContent = normalizedRaw || condensed;
        }

        if (fullLabelCandidate) {
            this.latestPrimaryLabel = fullLabelCandidate;
        }

        this._updateCompactPercent(detail);

        // UI surface logging: what the user actually sees on the nav bar.
        logEBookPageNumLimited('ui:primary-label', {
            label: fullLabelTarget.textContent || '',
            compactLabel: compactLabelTarget.textContent || '',
            hiddenOverlayLabel: overlayLabelTarget?.textContent || '',
            hiddenOverlayPercent: this.navHiddenOverlay?.percent?.textContent || '',
            hiddenOverlayLabelWidth: overlayLabelTarget?.offsetWidth ?? null,
            hiddenOverlayPercentWidth: this.navHiddenOverlay?.percent?.offsetWidth ?? null,
            labelVariant: this.navPrimaryText?.dataset?.labelVariant ?? null,
            source: this.lastPrimaryLabelDiagnostics?.source ?? null,
            current: this.lastPrimaryLabelDiagnostics?.currentPageNumber ?? null,
            total: this.lastPrimaryLabelDiagnostics?.totalPages ?? null,
            rendererSnapshotCurrent: this.rendererPageSnapshot?.current ?? null,
            rendererSnapshotTotal: this.rendererPageSnapshot?.total ?? null,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
        });
        logEPUBNav('nav.primaryLabel', {
            label: fullLabelTarget.textContent || '',
            compactLabel: compactLabelTarget.textContent || '',
            hiddenOverlayLabel: overlayLabelTarget?.textContent || '',
            labelVariant: this.navPrimaryText?.dataset?.labelVariant ?? null,
            source: this.lastPrimaryLabelDiagnostics?.source ?? null,
            currentPageNumber: this.lastPrimaryLabelDiagnostics?.currentPageNumber ?? null,
            currentPageSource: this.lastPrimaryLabelDiagnostics?.currentPageSource ?? null,
            totalPages: this.lastPrimaryLabelDiagnostics?.totalPages ?? null,
            totalSource: this.lastPrimaryLabelDiagnostics?.totalSource ?? null,
            fallbackTotalPages: this.fallbackTotalPageCount ?? null,
            pageTargetCount: this.totalPageCount || null,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            navHidden: this.navHidden,
        });
    }

    _applyLabelVariant() {
        if (!this.navPrimaryText?.dataset) return;
        const hide = this.hideNavigationDueToScroll || this.navHidden;
        this.navPrimaryText.dataset.labelVariant = hide ? 'compact' : 'full';
    }

    _syncLabelVariantFromDOM() {
        const barHidden = this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? false;
        const desiredHide = barHidden || this.hideNavigationDueToScroll || this.navHidden;
        if (this.navPrimaryText?.dataset) {
            const next = desiredHide ? 'compact' : 'full';
            const previousVariant = this.navPrimaryText.dataset.labelVariant ?? null;
            if (previousVariant !== next) {
                this.navPrimaryText.dataset.labelVariant = next;
                logEPUBNav('nav.visibility.variant-sync', {
                    previousVariant,
                    nextVariant: next,
                    barHidden,
                    hideNavigationDueToScroll: this.hideNavigationDueToScroll,
                    navHidden: this.navHidden,
                    navHiddenClass: this.navBar?.classList?.contains?.('nav-hidden') ?? null,
                    navHiddenScrollClass: this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
                    primaryLabel: this.navPrimaryTextFull?.textContent || this.navPrimaryText?.textContent || '',
                    compactLabel: this.navPrimaryTextCompact?.textContent || '',
                });
            }
        }
    }

    _updateCompactPercent(detail) {
        if (!this.navPrimaryPercent) return;
        const primary = this.navPrimaryPercent;
        const overlay = this.navHiddenOverlay?.percent;
        primary.textContent = '';
        primary.hidden = true;
        primary.setAttribute('aria-hidden', 'true');
        if (overlay) {
            overlay.textContent = '';
            overlay.hidden = true;
            overlay.setAttribute('aria-hidden', 'true');
        }
        logNavHide('hud:compact-percent', {
            isCompact: this.navPrimaryText?.dataset?.labelVariant === 'compact',
            hasValue: false,
            labelVariant: this.navPrimaryText?.dataset?.labelVariant ?? null,
            locationLabel: this.navPrimaryTextFull?.textContent || this.navPrimaryText?.textContent || '',
            compactLabel: this.navPrimaryTextCompact?.textContent || '',
            overlayLabel: this.navHiddenOverlay?.text?.textContent || '',
            overlayLabelHidden: this.navHiddenOverlay?.text?.hidden ?? null,
            overlayLabelWidth: this.navHiddenOverlay?.text?.offsetWidth ?? null,
            overlayPercent: overlay?.textContent || '',
            overlayPercentHidden: overlay?.hidden ?? null,
            overlayPercentWidth: overlay?.offsetWidth ?? null,
            overlayPercentDisplay: overlay ? window.getComputedStyle(overlay).display : null,
            overlayPercentVisibility: overlay ? window.getComputedStyle(overlay).visibility : null,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            navHidden: this.navHidden,
        });
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
        const reserveGap = 18;
        const leftVisible = !!this.navRelocateButtons?.back
            && !this.navRelocateButtons.back.hidden
            && this.navRelocateButtons.back.offsetWidth > 0
            && this.navRelocateButtons.back.dataset.navEdge === 'left';
        const rightVisible = !!this.navRelocateButtons?.back
            && !this.navRelocateButtons.back.hidden
            && this.navRelocateButtons.back.offsetWidth > 0
            && this.navRelocateButtons.back.dataset.navEdge === 'right';
        const leftForwardVisible = !!this.navRelocateButtons?.forward
            && !this.navRelocateButtons.forward.hidden
            && this.navRelocateButtons.forward.offsetWidth > 0
            && this.navRelocateButtons.forward.dataset.navEdge === 'left';
        const rightForwardVisible = !!this.navRelocateButtons?.forward
            && !this.navRelocateButtons.forward.hidden
            && this.navRelocateButtons.forward.offsetWidth > 0
            && this.navRelocateButtons.forward.dataset.navEdge === 'right';
        const leftInset = Math.max(
            leftVisible ? this.navRelocateButtons.back.offsetWidth + reserveGap : 0,
            leftForwardVisible ? this.navRelocateButtons.forward.offsetWidth + reserveGap : 0,
        );
        const rightInset = Math.max(
            rightVisible ? this.navRelocateButtons.back.offsetWidth + reserveGap : 0,
            rightForwardVisible ? this.navRelocateButtons.forward.offsetWidth + reserveGap : 0,
        );
        styleTarget.style.setProperty('--nav-left-aux-inset', `${leftInset}px`);
        styleTarget.style.setProperty('--nav-right-aux-inset', `${rightInset}px`);
        logNavHide('hud:aux-layout', {
            leftInset,
            rightInset,
            backButtonWidth: this.navRelocateButtons?.back?.offsetWidth ?? null,
            forwardButtonWidth: this.navRelocateButtons?.forward?.offsetWidth ?? null,
            backButtonHidden: this.navRelocateButtons?.back?.hidden ?? null,
            forwardButtonHidden: this.navRelocateButtons?.forward?.hidden ?? null,
            backButtonEdge: this.navRelocateButtons?.back?.dataset?.navEdge ?? null,
            forwardButtonEdge: this.navRelocateButtons?.forward?.dataset?.navEdge ?? null,
            pageTrackingContainerHidden: this.pageTrackingContainer?.hidden ?? null,
            pageTrackingButtonsHidden: this.pageTrackingButtons?.hidden ?? null,
            pageTrackingButtonCount: this.pageTrackingButtons?.childElementCount ?? 0,
            pageTrackingContainerWidth: this.pageTrackingContainer?.offsetWidth ?? null,
            pageTrackingButtonsWidth: this.pageTrackingButtons?.offsetWidth ?? null,
            pageTrackingContainerDisplay: this.pageTrackingContainer ? window.getComputedStyle(this.pageTrackingContainer).display : null,
            pageTrackingContainerVisibility: this.pageTrackingContainer ? window.getComputedStyle(this.pageTrackingContainer).visibility : null,
            pageTrackingOwnedByMainDocument: this.pageTrackingContainer?.ownerDocument === document,
            pageTrackingContainedByReaderStage: !!document.getElementById('reader-stage')?.contains(this.pageTrackingContainer),
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            navHidden: this.navHidden,
        });
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
            this._logPageNumberDiagnostic('primary-label.blocked', {
                reason: 'no-detail',
                totalPageCount: this.totalPageCount,
                fallbackTotalPageCount: this.fallbackTotalPageCount,
            });
            return null;
        }

        const metrics = this._computePageMetrics(detail);
        if (metrics?.currentPageNumber != null) {
            const currentPageNumber = metrics.currentPageNumber;
            const metricsTotal = metrics.totalPages;
            const totalPages = (
                typeof metricsTotal === 'number' && metricsTotal > 1
                    ? metricsTotal
                    : null
            );
            const label = totalPages != null
                ? `${currentPageNumber} of ${totalPages}`
                : `${currentPageNumber}`;
            this.lastPrimaryLabelDiagnostics = {
                source: 'page-metrics',
                label,
                currentPageNumber,
                totalPages,
                currentPageSource: metrics.diag?.currentSource ?? null,
                sectionIndex: metrics.diag?.sectionIndex ?? null,
                totalSource: metrics.diag?.totalSource ?? null,
                totalPageCount: this.totalPageCount,
            };
            this._logPageNumberDiagnostic('primary-label.derived', {
                label,
                currentPageNumber,
                totalPages,
                currentPageSource: metrics.diag?.currentSource ?? null,
                totalSource: metrics.diag?.totalSource ?? null,
                sectionIndex: metrics.diag?.sectionIndex ?? null,
                resolvedSectionHref: metrics.diag?.resolvedSectionHref ?? null,
            });
            this.latestPrimaryLabel = label;
            return label;
        }

        // If no page metrics are available yet, we won't show a label.
        this.latestPrimaryLabel = '';
        this.lastPrimaryLabelDiagnostics = {
            source: 'no-page-metrics',
            label: '',
            totalPageCount: this.totalPageCount,
            rawCurrentPageNumber: metrics?.diag?.rawCurrentPageNumber ?? null,
            rawCurrentSource: metrics?.diag?.rawCurrentSource ?? null,
            rawTotalPages: metrics?.diag?.rawTotalPages ?? null,
            currentPageReady: metrics?.diag?.currentPageReady ?? false,
            totalPagesReady: metrics?.diag?.totalPagesReady ?? false,
            sectionIndex: metrics?.diag?.sectionIndex ?? null,
            sectionIndexSource: metrics?.diag?.sectionIndexSource ?? null,
            resolvedSectionHref: metrics?.diag?.resolvedSectionHref ?? null,
            hasTrustedCurrentSectionCount: metrics?.diag?.hasTrustedCurrentSectionCount ?? false,
            cacheWarmerHighestSectionIndex: metrics?.diag?.cacheWarmerHighestSectionIndex ?? null,
            cacheWarmerReady: metrics?.diag?.cacheWarmerReady ?? false,
            locationTotal: metrics?.diag?.locationTotal ?? null,
            rendererSnapshotCurrent: metrics?.diag?.rendererSnapshotCurrent ?? null,
            rendererSnapshotTotal: metrics?.diag?.rendererSnapshotTotal ?? null,
        };
        this._logPageNumberDiagnostic('primary-label.blocked', {
            reason: metrics == null
                ? 'no-metrics'
                : metrics.diag?.sectionIndex == null
                    ? 'missing-section-index'
                    : metrics.diag?.currentPageReady !== true
                        ? 'current-page-not-ready'
                        : 'label-empty',
            rawCurrentPageNumber: metrics?.diag?.rawCurrentPageNumber ?? null,
            rawCurrentSource: metrics?.diag?.rawCurrentSource ?? null,
            rawTotalPages: metrics?.diag?.rawTotalPages ?? null,
            currentPageReady: metrics?.diag?.currentPageReady ?? false,
            totalPagesReady: metrics?.diag?.totalPagesReady ?? false,
            sectionIndex: metrics?.diag?.sectionIndex ?? null,
            sectionIndexSource: metrics?.diag?.sectionIndexSource ?? null,
            resolvedSectionHref: metrics?.diag?.resolvedSectionHref ?? null,
            hasTrustedCurrentSectionCount: metrics?.diag?.hasTrustedCurrentSectionCount ?? false,
            cacheWarmerHighestSectionIndex: metrics?.diag?.cacheWarmerHighestSectionIndex ?? null,
            cacheWarmerReady: metrics?.diag?.cacheWarmerReady ?? false,
            totalPageCount: this.totalPageCount,
            fallbackTotalPageCount: this.fallbackTotalPageCount,
        });
        return null;
    }

    _condensePrimaryLabel(label) {
        if (typeof label !== 'string') return '';
        const normalized = label.replace(/\s+/g, ' ').trim();
        const pageMatch = normalized.match(/^Page\s*(\d+)(?:\s+of\s+\d+)?$/i);
        if (pageMatch) {
            return pageMatch[1];
        }
        const totalMatch = normalized.match(/^(\d+)\s+of\s+\d+$/i);
        if (totalMatch) {
            return totalMatch[1];
        }
        // Otherwise strip any "of <total>" suffix (allowing for varied whitespace/non-breaking spaces).
        const trimmed = normalized.replace(/\s*of\s+.*$/i, '').trim();
        return trimmed || normalized;
    }

    _computePageMetrics(detail) {
        if (!detail) return null;
        const fraction = typeof detail.fraction === 'number' ? detail.fraction : null;
        const pageItem = detail.pageItem ?? null;
        const pageItemLabel = typeof pageItem?.label === 'string' ? pageItem.label : null;
        const pageItemKey = pageItem ? ensurePageKey(pageItem) : null;
        const pageIndex = this._resolvePageIndex(pageItem);
        const {
            index: sectionIndex,
            source: sectionIndexSource,
            resolvedHref: resolvedSectionHref,
        } = this._resolveSectionIndex(detail);
        const locationCurrent = typeof detail.location?.current === 'number' ? detail.location.current : null;
        const locationTotal = typeof detail.location?.total === 'number' ? detail.location.total : null;
        const detailPageNumber = typeof detail.pageNumber === 'number' ? detail.pageNumber : null;
        const detailPageCount = typeof detail.pageCount === 'number' ? detail.pageCount : null;
        const totalPagesRaw = this._currentTotalPages({
            detail,
            detailPageCount,
            sectionIndex,
        });
        const approxSectionIndexFromFraction =
            typeof detailPageCount === 'number' && detailPageCount > 0
                ? this._pageIndexFromFraction(fraction, detailPageCount)
                : null;
        const approxGlobalIndexFromFraction = this._globalPageIndexFromFraction(fraction, totalPagesRaw);
        const locationIndex = locationCurrent != null ? locationCurrent : null;
        const rendererIndex = this._rendererSnapshotIndex();
        const detailIndex = detailPageNumber != null ? detailPageNumber - 1 : null;
        const localSectionIndex = [detailIndex, rendererIndex, approxSectionIndexFromFraction]
            .find(index => typeof index === 'number' && index >= 0);
        const sectionPageNumber = localSectionIndex != null ? localSectionIndex + 1 : null;

        if (sectionIndex != null && detailPageCount != null) {
            this.lastSectionIndexSeen = sectionIndex;
            this.sectionPageCounts.set(sectionIndex, detailPageCount);
        }
        const sectionCountsState = this._sectionCountsState();
        const sectionOffset = sectionIndex != null ? this._sectionOffset(sectionIndex) : null;
        const pageTargetSectionOffset = sectionIndex != null ? this._pageTargetSectionOffset(sectionIndex) : null;
        const sectionsTotal = this.sectionPageCounts.size > 0
            ? Array.from(this.sectionPageCounts.values()).reduce((acc, value) => acc + (typeof value === 'number' && value > 0 ? value : 0), 0)
            : null;

        const globalIndexFromPageTargetSectionOffset =
            pageTargetSectionOffset != null && localSectionIndex != null
                ? pageTargetSectionOffset + localSectionIndex
                : null;
        const globalIndexFromSectionOffset =
            sectionOffset != null && localSectionIndex != null
                ? sectionOffset + localSectionIndex
                : null;
        const globalIndexFromLocation =
            totalPagesRaw != null
            && locationTotal != null
            && locationTotal === totalPagesRaw
            && locationIndex != null
                ? locationIndex
                : null;
        const globalIndex = [
            pageIndex,
            globalIndexFromPageTargetSectionOffset,
            globalIndexFromSectionOffset,
            globalIndexFromLocation,
            approxGlobalIndexFromFraction,
            sectionIndex == null ? detailIndex : null,
        ].find(index => typeof index === 'number' && index >= 0);
        const rawCurrent = globalIndex != null
            ? globalIndex + 1
            : (sectionPageNumber != null ? sectionPageNumber : null);
        const rawCurrentSource =
            pageIndex != null
                ? 'page-target'
                : globalIndexFromPageTargetSectionOffset != null
                    ? 'page-target-section-offset'
                    : globalIndexFromSectionOffset != null
                        ? 'section-offset'
                        : globalIndexFromLocation != null
                            ? 'location-global'
                            : approxGlobalIndexFromFraction != null
                                ? 'fraction-global'
                                : sectionIndex == null && detailIndex != null
                                    ? 'detail-global'
                                    : sectionPageNumber != null
                                        ? 'section-local'
                                        : null;
        const normalizedSectionIndex =
            sectionIndex == null
                ? null
                : Number.isFinite(Number(sectionIndex))
                    ? Number(sectionIndex)
                    : null;
        const hasTrustedCurrentSectionCount =
            sectionIndex != null
            && typeof this.sectionPageCounts.get(sectionIndex) === 'number'
            && this.sectionPageCounts.get(sectionIndex) > 0;
        const cacheWarmerFinished = this._cacheWarmerHasFinishedBook();
        const cacheWarmerHighestSectionIndex = this._cacheWarmerHighestSectionIndex();
        const currentPageReady = rawCurrent != null && (() => {
            if (rawCurrentSource === 'page-target' || rawCurrentSource === 'page-target-section-offset') {
                return true;
            }
            if (rawCurrentSource === 'section-offset') {
                return sectionOffset != null;
            }
            if (rawCurrentSource === 'location-global') {
                return normalizedSectionIndex != null;
            }
            return false;
        })();
        const adjustedCurrent = currentPageReady ? rawCurrent : null;
        const adjustedCurrentSource = currentPageReady ? rawCurrentSource : null;
        const rawTotal = totalPagesRaw != null ? totalPagesRaw : null;
        const totalPagesReady = rawTotal != null && (
            cacheWarmerFinished
            || this.lastTotalSource === 'location-global'
        );
        const adjustedTotal = totalPagesReady ? rawTotal : null;
        const totalPagesBlockedReason =
            rawTotal == null
                ? 'missing-raw-total'
                : !totalPagesReady
                    ? 'cachewarmer-not-finished'
                    : null;
        const diag = {
            fraction,
            pageItemKey,
            pageItemLabel,
            pageIndexFromItem: pageIndex,
            approxSectionIndexFromFraction,
            approxGlobalIndexFromFraction,
            locationCurrent,
            locationTotal,
            localSectionIndex,
            globalIndex,
            sectionIndex,
            normalizedSectionIndex,
            sectionOffset,
            resolvedSectionHref,
            pageTargetSectionOffset,
            sectionPageNumber,
            sectionPageCount: detailPageCount,
            detailPageNumber,
            detailPageCount,
            totalPageCount: this.totalPageCount,
            fallbackTotalPageCount: this.fallbackTotalPageCount,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
            rendererSnapshotCurrent: this.rendererPageSnapshot?.current ?? null,
            rendererSnapshotTotal: this.rendererPageSnapshot?.total ?? null,
            rawCurrentPageNumber: rawCurrent,
            rawCurrentSource,
            rawTotalPages: rawTotal,
            effectiveTotalPages: adjustedTotal ?? null,
            totalSource: totalPagesReady ? (this.lastTotalSource ?? null) : null,
            rawTotalSource: this.lastTotalSource ?? null,
            currentSource: adjustedCurrentSource,
            currentPageReady,
            hasTrustedCurrentSectionCount,
            totalPagesReady,
            totalPagesBlockedReason,
            cacheWarmerReady: cacheWarmerFinished,
            cacheWarmerHighestSectionIndex,
            sectionIndexSource,
            resolvedSectionHref,
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
            approxSectionIndexFromFraction,
            approxGlobalIndexFromFraction,
            locationIndex: locationCurrent,
            rendererIndex,
            localSectionIndex,
            globalIndex,
            sectionIndex,
            sectionIndexSource,
            sectionOffset,
            pageTargetSectionOffset,
            currentPageNumber: adjustedCurrent,
            currentPageSource: adjustedCurrentSource,
            totalPages: adjustedTotal,
            rawCurrentPageNumber: rawCurrent,
            rawCurrentSource,
            rawTotalPages: rawTotal,
            currentPageReady,
            totalPagesReady,
            totalPagesBlockedReason,
            cacheWarmerReady: cacheWarmerFinished,
            cacheWarmerHighestSectionIndex,
            totalPageCount: this.totalPageCount,
            rendererTotal: this.rendererPageSnapshot?.total ?? null,
            fallbackTotalPageCount: this.fallbackTotalPageCount,
            fallbackTotalPageCountSource: this.fallbackTotalPageCountSource ?? null,
            sectionsTotal,
            sectionCountsComplete: sectionCountsState.complete,
            sectionCountsFilledLinear: sectionCountsState.filledLinear,
            linearSectionCount: sectionCountsState.linearCount,
            locationTotal,
            detailPageNumber,
            detailPageCount,
            totalSource: this.lastTotalSource ?? null,
            hideNavigationDueToScroll: this.hideNavigationDueToScroll,
        });
        this._logTotalPagesGate({
            rawTotalPages: rawTotal,
            rawTotalSource: this.lastTotalSource ?? null,
            totalPagesReady,
            totalPagesBlockedReason,
            cacheWarmerFinished,
            cacheWarmerHighestSectionIndex,
            fallbackTotalPageCount: this.fallbackTotalPageCount,
            fallbackTotalPageCountSource: this.fallbackTotalPageCountSource ?? null,
            totalPageCount: this.totalPageCount,
            sectionsTotal,
            sectionCountsComplete: sectionCountsState.complete,
            sectionCountsFilledLinear: sectionCountsState.filledLinear,
            linearSectionCount: sectionCountsState.linearCount,
            missingLinearSectionIndexesPreview: sectionCountsState.missingLinearSectionIndexesPreview,
            sectionIndex,
            resolvedSectionHref,
        });
        if (!currentPageReady || !totalPagesReady) {
            this._logPageNumberDiagnostic('page-metrics.blocked', {
                currentPageReady,
                totalPagesReady,
                rawCurrentPageNumber: rawCurrent,
                rawCurrentSource,
                rawTotalPages: rawTotal,
                rawTotalSource: this.lastTotalSource ?? null,
                totalPagesBlockedReason,
                sectionIndex,
                sectionIndexSource,
                resolvedSectionHref,
                hasTrustedCurrentSectionCount,
                cacheWarmerFinished,
                cacheWarmerHighestSectionIndex,
                sectionPageCountsSize: this.sectionPageCounts.size,
                sectionMapSize: this.sectionIndexByHref?.size ?? 0,
                totalPageCount: this.totalPageCount,
                fallbackTotalPageCount: this.fallbackTotalPageCount,
                fallbackTotalPageCountSource: this.fallbackTotalPageCountSource ?? null,
                sectionCountsComplete: sectionCountsState.complete,
                sectionCountsFilledLinear: sectionCountsState.filledLinear,
                linearSectionCount: sectionCountsState.linearCount,
                missingLinearSectionIndexesPreview: sectionCountsState.missingLinearSectionIndexesPreview,
            });
        }
        return {
            currentPageNumber: adjustedCurrent,
            totalPages: adjustedTotal,
            sectionIndex,
            pageItemLabel,
            diag,
        };
    }

    _resolveSectionIndex(detail) {
        const renderer = this.getRenderer?.() ?? null;
        const rendererContent = getPrimaryRendererContent(renderer);
        const candidates = [
            { source: 'detail.sectionIndex', value: detail?.sectionIndex },
            { source: 'detail.index', value: detail?.index },
            { source: 'renderer.contents[0].index', value: rendererContent?.index },
            { source: 'renderer.currentIndex', value: renderer?.currentIndex },
            { source: 'last-relocate.sectionIndex', value: this.lastRelocateDetail?.sectionIndex },
            { source: 'last-relocate.index', value: this.lastRelocateDetail?.index },
            { source: 'last-section-seen', value: this.lastSectionIndexSeen },
        ];
        for (const candidate of candidates) {
            if (typeof candidate.value === 'number' && candidate.value >= 0) {
                this._logPageNumberDiagnostic('section-index.resolved', {
                    resolution: 'numeric',
                    source: candidate.source,
                    resolvedHref: null,
                    sectionIndex: candidate.value,
                    sectionMapSize: this.sectionIndexByHref?.size ?? 0,
                });
                return { index: candidate.value, source: candidate.source, resolvedHref: null };
            }
        }
        const hrefCandidates = [
            { source: 'renderer.contents[0].doc.body.dataset.manabiSourceHref', value: getRendererContentHref(renderer) },
            { source: 'detail.tocItem.href', value: detail?.tocItem?.href },
            { source: 'renderer.tocItem.href', value: renderer?.tocItem?.href },
            { source: 'last-location.tocItem.href', value: globalThis.reader?.view?.lastLocation?.tocItem?.href },
        ];
        const hrefCandidateSummary = hrefCandidates.map((candidate) => {
            const normalizedHref = normalizeSpineHrefForPageNum(candidate.value);
            return {
                source: candidate.source,
                href: candidate.value ?? null,
                normalizedHref,
                mappedIndex: normalizedHref != null ? (this.sectionIndexByHref?.get(normalizedHref) ?? null) : null,
            };
        });
        for (const candidate of hrefCandidates) {
            const normalizedHref = normalizeSpineHrefForPageNum(candidate.value);
            const indexFromHref = normalizedHref != null ? (this.sectionIndexByHref?.get(normalizedHref) ?? null) : null;
            if (typeof indexFromHref === 'number' && indexFromHref >= 0) {
                this._logPageNumberDiagnostic('section-index.resolved', {
                    resolution: 'href',
                    source: candidate.source,
                    resolvedHref: normalizedHref,
                    sectionIndex: indexFromHref,
                    sectionMapSize: this.sectionIndexByHref?.size ?? 0,
                });
                return { index: indexFromHref, source: candidate.source, resolvedHref: normalizedHref };
            }
        }
        const hasSectionMetadata = (this.sectionIndexByHref?.size ?? 0) > 0
            || (Array.isArray(this.navContext?.sections) && this.navContext.sections.length > 0);
        if (!hasSectionMetadata) {
            this._logPageNumberDiagnostic('section-index.pending-metadata', {
                hrefCandidates: hrefCandidateSummary,
                sectionMapSize: this.sectionIndexByHref?.size ?? 0,
                navSectionCount: Array.isArray(this.navContext?.sections) ? this.navContext.sections.length : 0,
            });
            return { index: null, source: 'none', resolvedHref: null };
        }
        this._logPageNumberDiagnostic('section-index.unresolved', {
            hrefCandidates: hrefCandidateSummary,
            numericCandidates: candidates.map((candidate) => ({
                source: candidate.source,
                value: typeof candidate.value === 'number' ? candidate.value : null,
            })),
            sectionMapSize: this.sectionIndexByHref?.size ?? 0,
        });
        return { index: null, source: 'none', resolvedHref: null };
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
            const sectionResolution = this._resolveSectionIndex(this.lastRelocateDetail ?? this.currentLocationDescriptor ?? null);
            const pagesLeft = await this._calculatePagesLeftInSection({ refreshSnapshot });
            const showingCompletion = this.navContext?.showingFinish || this.navContext?.showingRestart;
            if (this.hideNavigationDueToScroll || showingCompletion) return;
            if (sectionResolution.index == null) return;
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
                sectionIndex: sectionResolution.index,
                sectionIndexSource: sectionResolution.source,
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
        const sectionResolution = this._resolveSectionIndex(detail ?? this.currentLocationDescriptor ?? null);
        if (sectionResolution.index == null) return null;
        const cachedSectionTotal = this.sectionPageCounts.get(sectionResolution.index);
        if (!(typeof cachedSectionTotal === 'number' && cachedSectionTotal > 0)) {
            return null;
        }
        if (refreshSnapshot) {
            await this._refreshRendererSnapshot();
        }
        const localCurrentIndex = this._rendererSnapshotIndex();
        if (!(typeof localCurrentIndex === 'number' && localCurrentIndex >= 0)) {
            return null;
        }
        const currentPageNumber = localCurrentIndex + 1;
        return Math.max(0, cachedSectionTotal - currentPageNumber);
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
        const line = `# PAGENUM ${JSON.stringify(cleaned)}`;
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

    _rebuildPageTargetSectionMetrics() {
        this.pageTargetSectionPageCounts = new Map();
        this.pageTargetSectionOffsets = new Map();
        const sections = Array.isArray(this.navContext?.sections) ? this.navContext.sections : [];
        if (!sections.length || !Array.isArray(this.pageTargets) || !this.pageTargets.length) return;
        const sectionIndexByHref = new Map();
        sections.forEach((section, index) => {
            if (section?.linear === 'no') return;
            const normalizedHref = normalizeSpineHrefForPageNum(section?.href ?? section?.id ?? null);
            if (normalizedHref) {
                sectionIndexByHref.set(normalizedHref, index);
            }
        });
        this.pageTargets.forEach((pageTarget) => {
            const normalizedHref = normalizeSpineHrefForPageNum(pageTarget?.href ?? null);
            const sectionIndex = normalizedHref != null ? sectionIndexByHref.get(normalizedHref) : null;
            if (typeof sectionIndex === 'number') {
                this.pageTargetSectionPageCounts.set(sectionIndex, (this.pageTargetSectionPageCounts.get(sectionIndex) ?? 0) + 1);
            }
        });
        let runningOffset = 0;
        sections.forEach((section, index) => {
            if (section?.linear === 'no') return;
            const count = this.pageTargetSectionPageCounts.get(index);
            if (typeof count === 'number' && count > 0) {
                this.pageTargetSectionOffsets.set(index, runningOffset);
                runningOffset += count;
            }
        });
    }

    _pageTargetSectionOffset(sectionIndex) {
        if (sectionIndex == null || sectionIndex < 0) return null;
        return this.pageTargetSectionOffsets.get(sectionIndex) ?? null;
    }

    _cacheWarmerHighestSectionIndex() {
        const highest = globalThis.__manabiCacheWarmerHighestSectionIndex;
        return typeof highest === 'number' && highest >= 0 ? highest : null;
    }

    _cacheWarmerHasReachedCurrentSection(sectionIndex) {
        if (sectionIndex == null) return false;
        if (sectionIndex <= 0) return true;
        const highest = this._cacheWarmerHighestSectionIndex();
        return highest != null && highest >= sectionIndex - 1;
    }

    _cacheWarmerHasFinishedBook() {
        return !!globalThis.__manabiCacheWarmerFinished;
    }
    
    _pageIndexFromFraction(fraction, totalOverride) {
        const total = typeof totalOverride === 'number' && totalOverride > 0
            ? totalOverride
            : (this.totalPageCount > 0 ? this.totalPageCount : null);
        if (typeof fraction !== 'number' || !total) return null;
        const approx = Math.round(Math.max(0, Math.min(1, fraction)) * Math.max(total - 1, 0));
        return Math.max(0, Math.min(total - 1, approx));
    }

    _globalPageIndexFromFraction(fraction, totalOverride) {
        const total = typeof totalOverride === 'number' && totalOverride > 0
            ? totalOverride
            : null;
        if (typeof fraction !== 'number' || !total) return null;
        const approx = Math.round(Math.max(0, Math.min(1, fraction)) * Math.max(total - 1, 0));
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
        if (sectionIndex == null || sectionIndex < 0) return null;
        if (sectionIndex === 0) return 0;
        let sum = 0;
        for (let i = 0; i < sectionIndex; i += 1) {
            const count = this.sectionPageCounts.get(i);
            if (typeof count === 'number' && count > 0) {
                sum += count;
            } else {
                return null;
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

    _sectionCountsState() {
        const linearIndexes = Array.from(this.linearSectionIndexes ?? []);
        const filledLinearIndexes = linearIndexes.filter(idx => this.sectionPageCounts.has(idx));
        const missingLinearIndexes = linearIndexes.filter(idx => !this.sectionPageCounts.has(idx));
        return {
            complete: this._hasCompleteSectionCounts(),
            linearCount: this.linearSectionCount ?? 0,
            filledLinear: filledLinearIndexes.length,
            missingLinearSectionIndexesPreview: missingLinearIndexes.slice(0, 8),
            sectionPageCountsSize: this.sectionPageCounts.size,
        };
    }

    _currentTotalPages({ detail, detailPageCount, sectionIndex }) {
        const candidates = [];
        if (this.totalPageCount > 0) {
            candidates.push({ source: 'page-targets', total: this.totalPageCount });
        }
        if (this.sectionPageCounts.size > 0 && this._hasCompleteSectionCounts()) {
            const sectionSum = Array.from(this.sectionPageCounts.values())
                .reduce((acc, value) => acc + (typeof value === 'number' && value > 0 ? value : 0), 0);
            if (sectionSum > 0) {
                candidates.push({ source: 'sections', total: sectionSum });
                this._updateFallbackTotalPages(sectionSum, 'sections');
            }
        }
        const locationTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        if (locationTotal && locationTotal > 0) {
            candidates.push({ source: 'location-global', total: locationTotal });
        }
        if (
            typeof this.fallbackTotalPageCount === 'number'
            && this.fallbackTotalPageCount > 0
            && ['page-targets', 'sections', 'cachewarmer'].includes(this.fallbackTotalPageCountSource)
        ) {
            candidates.push({
                source: `fallback:${this.fallbackTotalPageCountSource}`,
                total: this.fallbackTotalPageCount,
            });
        }
        if (!candidates.length) {
            this.lastTotalSource = null;
            return null;
        }
        const locationCandidate = candidates.find(candidate => candidate.source === 'location-global') ?? null;
        const pageBasedPrecedence = ['page-targets', 'sections', 'fallback:page-targets', 'fallback:sections', 'fallback:cachewarmer'];
        const bestPageBased = candidates
            .filter(candidate => candidate.source !== 'location-global')
            .sort((a, b) => {
                const pa = pageBasedPrecedence.indexOf(a.source);
                const pb = pageBasedPrecedence.indexOf(b.source);
                if (pa !== pb) return pa - pb;
                return (b.total ?? 0) - (a.total ?? 0);
            })[0] ?? null;

        const best = bestPageBased ?? locationCandidate;
        this.lastTotalSource = best?.source ?? null;
        const summary = candidates.map(({ source, total }) => ({ source, total }));
        const changed = !this.lastTotalPagesSnapshot
            || this.lastTotalPagesSnapshot.source !== (best?.source ?? null)
            || this.lastTotalPagesSnapshot.total !== (best?.total ?? null)
            || this.lastTotalPagesSnapshot.candidateCount !== summary.length;
        if (changed) {
            const sectionCountsState = this._sectionCountsState();
            logEBookPageNumLimited('nav:total-pages-source', {
                chosenSource: best?.source ?? null,
                chosenTotal: best?.total ?? null,
                candidates: summary,
                sectionCountsComplete: sectionCountsState.complete,
                sectionCountsFilledLinear: sectionCountsState.filledLinear,
                linearSectionCount: sectionCountsState.linearCount,
                missingLinearSectionIndexesPreview: sectionCountsState.missingLinearSectionIndexesPreview,
                fallbackTotalPageCount: this.fallbackTotalPageCount ?? null,
                fallbackTotalPageCountSource: this.fallbackTotalPageCountSource ?? null,
                cacheWarmerFinished: this._cacheWarmerHasFinishedBook(),
                cacheWarmerHighestSectionIndex: this._cacheWarmerHighestSectionIndex(),
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
            prev.globalIndex !== payload.globalIndex ||
            prev.localSectionIndex !== payload.localSectionIndex ||
            prev.currentPageSource !== payload.currentPageSource ||
            prev.currentPageReady !== payload.currentPageReady ||
            prev.totalPagesReady !== payload.totalPagesReady ||
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
            globalIndex: payload.globalIndex ?? null,
            localSectionIndex: payload.localSectionIndex ?? null,
            currentPageSource: payload.currentPageSource ?? null,
            currentPageReady: !!payload.currentPageReady,
            totalPagesReady: !!payload.totalPagesReady,
            rawCurrentPageNumber: payload.rawCurrentPageNumber ?? null,
            rawCurrentSource: payload.rawCurrentSource ?? null,
            rawTotalPages: payload.rawTotalPages ?? null,
            totalSource: payload.totalSource ?? null,
            sectionOffset: payload.sectionOffset ?? null,
            sectionIndex: payload.sectionIndex ?? null,
            sectionIndexSource: payload.sectionIndexSource ?? null,
            resolvedSectionHref: payload.resolvedSectionHref ?? null,
            fraction: payload.fraction ?? null,
        };
        logEBookPageNumLimited('nav:page-metrics', payload);
        logEPUBNav('page.metrics', {
            currentPageNumber: payload.currentPageNumber ?? null,
            currentPageSource: payload.currentPageSource ?? null,
            currentPageReady: !!payload.currentPageReady,
            totalPages: payload.totalPages ?? null,
            totalPagesReady: !!payload.totalPagesReady,
            rawCurrentPageNumber: payload.rawCurrentPageNumber ?? null,
            rawCurrentSource: payload.rawCurrentSource ?? null,
            rawTotalPages: payload.rawTotalPages ?? null,
            sectionIndex: payload.sectionIndex ?? null,
            sectionIndexSource: payload.sectionIndexSource ?? null,
            resolvedSectionHref: payload.resolvedSectionHref ?? null,
            sectionOffset: payload.sectionOffset ?? null,
            pageTargetSectionOffset: payload.pageTargetSectionOffset ?? null,
            globalIndex: payload.globalIndex ?? null,
            localSectionIndex: payload.localSectionIndex ?? null,
            detailPageNumber: payload.detailPageNumber ?? null,
            detailPageCount: payload.detailPageCount ?? null,
            pageIndexFromItem: payload.pageIndexFromItem ?? null,
            rendererIndex: payload.rendererIndex ?? null,
            locationIndex: payload.locationIndex ?? null,
            totalSource: payload.totalSource ?? null,
            cacheWarmerReady: !!payload.cacheWarmerReady,
            cacheWarmerHighestSectionIndex: payload.cacheWarmerHighestSectionIndex ?? null,
            totalPageCount: payload.totalPageCount ?? null,
            fallbackTotalPageCount: payload.fallbackTotalPageCount ?? null,
            sectionsTotal: payload.sectionsTotal ?? null,
            locationTotal: payload.locationTotal ?? null,
            fraction: payload.fraction ?? null,
        });
    }

    _logTotalPagesGate(payload) {
        const snapshot = {
            rawTotalPages: payload.rawTotalPages ?? null,
            rawTotalSource: payload.rawTotalSource ?? null,
            totalPagesReady: !!payload.totalPagesReady,
            totalPagesBlockedReason: payload.totalPagesBlockedReason ?? null,
            cacheWarmerFinished: !!payload.cacheWarmerFinished,
            cacheWarmerHighestSectionIndex: payload.cacheWarmerHighestSectionIndex ?? null,
            fallbackTotalPageCount: payload.fallbackTotalPageCount ?? null,
            fallbackTotalPageCountSource: payload.fallbackTotalPageCountSource ?? null,
            totalPageCount: payload.totalPageCount ?? null,
            sectionsTotal: payload.sectionsTotal ?? null,
            sectionCountsComplete: !!payload.sectionCountsComplete,
            sectionCountsFilledLinear: payload.sectionCountsFilledLinear ?? null,
            linearSectionCount: payload.linearSectionCount ?? null,
            sectionIndex: payload.sectionIndex ?? null,
            resolvedSectionHref: payload.resolvedSectionHref ?? null,
        };
        const prev = this.lastTotalPagesGateSnapshot;
        const changed = !prev
            || Object.keys(snapshot).some(key => snapshot[key] !== prev[key])
            || JSON.stringify(payload.missingLinearSectionIndexesPreview ?? []) !== JSON.stringify(prev?.missingLinearSectionIndexesPreview ?? []);
        if (!changed) return;
        this.lastTotalPagesGateSnapshot = {
            ...snapshot,
            missingLinearSectionIndexesPreview: payload.missingLinearSectionIndexesPreview ?? [],
        };
        logEBookPageNumLimited('nav:total-pages-gate', {
            ...snapshot,
            missingLinearSectionIndexesPreview: payload.missingLinearSectionIndexesPreview ?? [],
        });
        logEPUBNav('total-pages.gate', {
            ...snapshot,
            missingLinearSectionIndexesPreview: payload.missingLinearSectionIndexesPreview ?? [],
        });
    }

    _updateFallbackTotalPages(total, source = 'unknown') {
        if (typeof total !== 'number' || total <= 0) return;
        if (!['page-targets', 'sections', 'cachewarmer'].includes(source)) return;
        if (!this.fallbackTotalPageCount || total > this.fallbackTotalPageCount) {
            this.fallbackTotalPageCount = total;
            this.fallbackTotalPageCountSource = source;
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
            ?? null;
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
