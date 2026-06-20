const MAX_RELOCATE_STACK = 50;
const FRACTION_EPSILON = 0.000001;
const EXPLICIT_RELOCATE_HISTORY_SOURCES = new Set([
    'bridge.goToReaderPage',
    'bridge.goToReaderLocation',
    'bridge.goToReaderPercent',
    'bridge.goToReaderHref',
    'goToPercent',
    'goToLocation',
    'goToHref',
    'relocate-button',
    'scrub-release',
]);

const MANABI_NAV_SENTINEL_ADJUST_ENABLED = true;
const bookNavRect = (element) => {
    const rect = element?.getBoundingClientRect?.() ?? null;
    if (!rect) return null;
    return {
        x: safeRound(rect.x, 1),
        y: safeRound(rect.y, 1),
        width: safeRound(rect.width, 1),
        height: safeRound(rect.height, 1),
        top: safeRound(rect.top, 1),
        bottom: safeRound(rect.bottom, 1),
    };
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

const getPrimaryRendererContentIndex = (renderer) => {
    const content = getPrimaryRendererContent(renderer);
    return typeof content?.index === 'number' ? content.index : null;
};

const getRendererContentHref = (renderer) => {
    const content = getPrimaryRendererContent(renderer);
    const datasetHref = content?.doc?.body?.dataset?.mnbSourceHref;
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

const deriveLocationIndexFromFraction = (fraction, total) => {
    if (typeof fraction !== 'number' || !isFinite(fraction)) return null;
    if (typeof total !== 'number' || !isFinite(total) || total <= 0) return null;
    const clampedFraction = Math.max(0, Math.min(1, fraction));
    const clampedTotal = Math.max(1, Math.round(total));
    if (clampedTotal <= 1) return 0;
    return Math.max(0, Math.min(clampedTotal - 1, Math.round(clampedFraction * (clampedTotal - 1))));
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

const safeRound = (value, digits = 1) =>
    globalThis.__manabiSafeRound?.(value, digits)
        ?? (typeof value === 'number' && Number.isFinite(value)
            ? Number(value.toFixed(digits))
            : null);

const readerNavLoadLog = (stage, payload = {}) => {
    try {
        globalThis.__manabiReaderLoadLog?.(stage, payload);
    } catch (_error) {}
};

export class NavigationHUD {
    constructor({ onJumpRequest, getRenderer, formatPercent, onHideNavigationDueToScrollChange } = {}) {
        this.onJumpRequest = onJumpRequest;
        this.getRenderer = getRenderer;
        this.formatPercent = formatPercent ?? (value => `${Math.round(value * 100)}%`);
        this.onHideNavigationDueToScrollChange = onHideNavigationDueToScrollChange;
        
        this.navBar = document.getElementById('nav-bar');
        this.navPrimaryText = document.getElementById('nav-primary-text');
        this.navPrimaryTextFull = document.getElementById('nav-primary-text-full');
        this.navPrimaryTextCompact = document.getElementById('nav-primary-text-compact');
        this.navHiddenOverlay = {
            text: document.getElementById('nav-hidden-primary-text'),
            percent: document.getElementById('nav-hidden-primary-percent'),
        };
        this.navTitleLocationLabel = document.getElementById('nav-title-location-label');
        this.navSectionProgress = {
            leading: document.getElementById('nav-section-progress-leading'),
            trailing: document.getElementById('nav-section-progress-trailing'),
            center: document.getElementById('nav-section-progress-center'),
        };
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
        this._explicitRelocateHistoryMutationSource = null;
        this.scrubSession = null;
        this.pendingReleasedScrubDescriptor = null;
        this.pendingRelocateJump = null;
        this.primaryLineRequestToken = 0;
        this.rendererPageSnapshot = null;
        this.nativeOverlayPageSnapshot = null;
        this.rendererSnapshotRefreshHandle = null;
        this.lastTerminalPagesLeftSection = null;
        this.lastTerminalPagesLeftPageNumber = null;
        this.sectionProgressRequestToken = 0;
        this.latestPrimaryLabel = '';
        this.previousRelocateVisibility = {
            back: null,
            forward: null,
        };
        this.lastPrimaryLabelDiagnostics = null;
        this.lastPercentDecisionSignature = null;
        this.fallbackTotalPageCount = null;
        this.lastTotalSource = null;
        this.lastTotalPagesSnapshot = null;
        this.lastScrubberFraction = null;
        this.lastKnownLocationTotal = null;
        this.navHidden = false;
        this.bookTitle = '';
        this.lastPagesLeftLabel = '';
        this.auxiliaryInsetsFrame = 0;
        this.lastAuxiliaryInsetsState = null;
        this._applyLabelVariant();
        if (this.pendingScrubCommit) {
            this.pendingScrubCommit = null;
        }

        this._updateRelocateButtons();
        this._applyRelocateButtonEdges();
    }

    requestExplicitRelocateHistoryMutation(source = 'unknown') {
        this._explicitRelocateHistoryMutationSource = source;
    }

    #consumeExplicitRelocateHistoryMutation() {
        const source = this._explicitRelocateHistoryMutationSource ?? null;
        this._explicitRelocateHistoryMutationSource = null;
        if (source) {
        }
        return source;
    }

    linearSectionCount = null;
    linearSectionIndexes = new Set();
    pageTargetSectionPageCounts = new Map();
    pageTargetSectionOffsets = new Map();

    setIsRTL(isRTL) {
        this.isRTL = !!isRTL;
        this._applyRelocateButtonEdges();
        this._updateSectionProgress({ source: 'rtl' });
        this._requestAuxiliaryInsetsUpdate();
    }

    setSectionPageCountsFromCache(counts) {
        // Cache-warmer page counts are intentionally ignored. The visible label is location-driven.
        return;
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
        this.linearSectionCount = this.linearSectionIndexes.size || null;
        this._rebuildPageTargetSectionMetrics();
        if (this.lastRelocateDetail) {
            this._updateRendererSnapshotFromDetail(this.lastRelocateDetail);
            this._updatePrimaryLine(this.lastRelocateDetail);
        }
        // Keep completion button visibility controlled by navigation state rather than scroll visibility.
        // This prevents finish/restart controls from disappearing when the nav is hidden during scroll.
        const showingCompletion = !!(this.navContext?.showingFinish || this.navContext?.showingRestart);
        this._toggleCompletionStack(showingCompletion);
        this._updateSectionProgress({ source: 'nav-context' });
        this._updateRelocateButtons();
    }
    
    setHideNavigationDueToScroll(shouldHide, source = 'unknown', context = null) {
        const sequence = (globalThis.__manabiNavVisibilitySequence = Number(globalThis.__manabiNavVisibilitySequence || 0) + 1);
        const previous = this.hideNavigationDueToScroll;
        const next = !!shouldHide;
        const previousClass = this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? false;
        if (!next && globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay === true) {
            this.onHideNavigationDueToScrollChange?.(this.hideNavigationDueToScroll, {
                source,
                previous,
                context: {
                    ...(context || {}),
                    resyncReason: 'preservedHiddenNavigation',
                },
            });
            return this.hideNavigationDueToScroll;
        }
        if (previous === next && previousClass === next) {
            this.onHideNavigationDueToScrollChange?.(this.hideNavigationDueToScroll, {
                source,
                previous,
                context: {
                    ...(context || {}),
                    resyncReason: 'noop',
                },
            });
            return this.hideNavigationDueToScroll;
        }
        this.hideNavigationDueToScroll = next;
        this.navBar?.classList.toggle('nav-hidden-due-to-scroll', this.hideNavigationDueToScroll);
        this.onHideNavigationDueToScrollChange?.(this.hideNavigationDueToScroll, {
            source,
            previous,
            context,
        });
        this._applyLabelVariant();
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
        // Keep completion stack state untouched while animating scroll-hide to avoid dropping finish/restart.
        this._updateRelocateButtons(`setHide:${source}`);
        this.syncPageTrackingButtonsNavigationDisabled();
        this.refreshTitleLocationVisibility(`setHide:${source}`);
        void this._updateSectionProgress({ refreshSnapshot: false, source: `setHide:${source}` });
        this._postNativeOverlayState(`setHide:${source}`);
        this._requestAuxiliaryInsetsUpdate();
    }

    _captureHideNavState() {
        return {
            bodyNavHiddenClass: document.body?.classList?.contains?.('nav-hidden') ?? null,
            bodyNavHiddenScrollClass: document.body?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            navHidden: this.navHidden,
            navHiddenClass: this.navBar?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: this.navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            hudHideNavigationDueToScroll: this.hideNavigationDueToScroll,
            labelVariant: this.navPrimaryText?.dataset?.labelVariant ?? null,
            preserveHiddenThroughNextDisplay: globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay === true,
            ignoreRevealCount: Number(globalThis.__manabiIgnoreNextIncomingRevealNavigationCount || 0),
            ignoreHideCount: Number(globalThis.__manabiIgnoreNextIncomingHideNavigationCount || 0),
        };
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
        this.refreshTitleLocationVisibility('nav-hidden-state');
        this._postNativeOverlayState('nav-hidden-state');
    }

    setBookTitle(title) {
        const normalized = typeof title === 'string' ? title.replace(/\s+/g, ' ').trim() : '';
        this.bookTitle = normalized;
        this.refreshTitleLocationVisibility('book-title');
    }

    refreshTitleLocationVisibility(source = 'refresh') {
        this._updateTitleLocationLabel({ source });
    }

    syncPageTrackingButtonsNavigationDisabled() {
        const shouldDisable =
            document.body?.dataset?.mnbMarkReadButtonsHideWithNavigation === 'true'
            && (this.hideNavigationDueToScroll || this.navHidden);
        const buttons = this.pageTrackingButtons?.querySelectorAll?.('button.page-read-button') ?? [];
        for (const button of buttons) {
            if (!(button instanceof HTMLButtonElement)) continue;
            if (shouldDisable) {
                if (!button.disabled) {
                    button.dataset.mnbDisabledForHiddenNavigation = 'true';
                    button.disabled = true;
                }
            } else if (button.dataset.mnbDisabledForHiddenNavigation === 'true') {
                delete button.dataset.mnbDisabledForHiddenNavigation;
                button.disabled = false;
            }
        }
    }

    _titleLocationVisibilityMode() {
        const raw = document.body?.dataset?.mnbEbookTitleLocationVisibility;
        return raw === 'automatic' ? 'automatic' : 'alwaysVisible';
    }

    _applyTitleLocationUIFont() {
        const target = this.navTitleLocationLabel;
        if (!target?.style) return;
        target.style.setProperty('font-family', '-apple-system, BlinkMacSystemFont, system-ui, sans-serif', 'important');
        target.style.setProperty('font-size', '10px', 'important');
        target.style.setProperty('font-weight', '600', 'important');
        target.style.setProperty('line-height', '12px', 'important');
    }

    _titleLocationTextLayers() {
        const target = this.navTitleLocationLabel;
        if (!target) return null;
        let layers = Array.from(target.querySelectorAll(':scope > .nav-title-location-text'));
        if (layers.length === 2) {
            return layers;
        }
        const existingText = target.textContent ?? '';
        target.textContent = '';
        layers = [document.createElement('span'), document.createElement('span')];
        for (const layer of layers) {
            layer.className = 'nav-title-location-text';
            layer.setAttribute('aria-hidden', 'true');
            target.append(layer);
        }
        if (existingText) {
            layers[0].textContent = existingText;
            layers[0].dataset.active = 'true';
            target.dataset.activeTitleLocationLayer = '0';
        }
        return layers;
    }

    _setTitleLocationLabel(visible, label = '') {
        const target = this.navTitleLocationLabel;
        if (!target) return;
        this._applyTitleLocationUIFont();
        const layers = this._titleLocationTextLayers();
        if (!layers) return;
        if (target.__titleLocationFadeTimer) {
            clearTimeout(target.__titleLocationFadeTimer);
            target.__titleLocationFadeTimer = null;
        }
        if (visible && label) {
            target.hidden = false;
            const activeIndex = target.dataset.activeTitleLocationLayer === '1' ? 1 : 0;
            const activeLayer = layers[activeIndex];
            if (target.dataset.visible === 'true' && activeLayer?.textContent === label) {
                target.removeAttribute('aria-hidden');
                return;
            }
            const nextIndex = activeLayer?.textContent ? 1 - activeIndex : activeIndex;
            const nextLayer = layers[nextIndex];
            nextLayer.textContent = label;
            nextLayer.dataset.active = 'true';
            if (nextLayer !== activeLayer) {
                activeLayer.dataset.active = 'false';
            }
            target.dataset.activeTitleLocationLayer = `${nextIndex}`;
            target.dataset.titleLocationText = label;
            target.dataset.visible = 'true';
            target.removeAttribute('aria-hidden');
            return;
        }
        target.dataset.visible = 'false';
        target.setAttribute('aria-hidden', 'true');
        for (const layer of layers) {
            layer.dataset.active = 'false';
        }
        target.__titleLocationFadeTimer = setTimeout(() => {
            if (target.dataset.visible === 'false') {
                for (const layer of layers) {
                    layer.textContent = '';
                }
                target.dataset.titleLocationText = '';
                target.hidden = true;
            }
            target.__titleLocationFadeTimer = null;
        }, 260);
    }

    _updateTitleLocationLabel({ pagesLeftLabel = null, pagesLeftVisible = null, source = 'refresh' } = {}) {
        if (typeof pagesLeftLabel === 'string') {
            this.lastPagesLeftLabel = pagesLeftLabel;
        }
        const mode = this._titleLocationVisibilityMode();
        const isHidden = this.hideNavigationDueToScroll || this.navHidden;
        if (isHidden) {
            if (mode === 'automatic') {
                this._setTitleLocationLabel(false);
                this._postNativeOverlayState(`title-location:${source}`);
                return;
            }
            this._setTitleLocationLabel(!!this.bookTitle, this.bookTitle);
            this._postNativeOverlayState(`title-location:${source}`);
            return;
        }
        const shouldShowPagesLeft = pagesLeftVisible === null
            ? !!this.lastPagesLeftLabel
            : !!pagesLeftVisible;
        this._setTitleLocationLabel(shouldShowPagesLeft, shouldShowPagesLeft ? this.lastPagesLeftLabel : '');
        this._postNativeOverlayState(`title-location:${source}`);
    }

    getCurrentDescriptor() {
        return this._cloneDescriptor(this.currentLocationDescriptor);
    }

    getCurrentLocationDescriptor() {
        return this.getCurrentDescriptor();
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
                }
            } else if (this.pendingScrubCommit) {
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
        if (!cancel && session.originDescriptor && releaseMoved) {
            this.pendingScrubCommit = {
                origin: this._cloneDescriptor(session.originDescriptor),
                reason: 'scrub-release',
                releaseFraction: releaseValue,
                scheduledAt: Date.now(),
                releaseDescriptor: comparisonDescriptor,
            };
            deferredCommit = true;
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
        this.pendingReleasedScrubDescriptor = releaseDescriptor
            ? this._cloneDescriptor(releaseDescriptor)
            : null;
        this.scrubSession = null;
        this._updateRelocateButtons();
        if (comparisonDescriptor || this.currentLocationDescriptor) {
            this._updatePrimaryLine(comparisonDescriptor || this.currentLocationDescriptor);
        }
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
        const detailSnapshot = this._updateRendererSnapshotFromDetail(detail);
        if (detailSnapshot) {
            this._scheduleRendererSnapshotRefresh('relocate-detail');
        } else {
            await this._refreshRendererSnapshot();
        }
        this._applyPageTurnNavigationVisibility(detail);
        this.lastRelocateDetail = detail;
        this._handleRelocateHistory(detail);
        this._updatePrimaryLine(detail);
        this._toggleCompletionStack();
        await this._updateSectionProgress({ refreshSnapshot: false, source: 'relocate' });
        this._updateRelocateButtons();
        this._pruneBackStackIfReturnedToOrigin(detail);
    }

    _applyPageTurnNavigationVisibility(detail) {
        const reportedDirection = typeof detail?.pageTurnDirection === 'string'
            ? detail.pageTurnDirection.toLowerCase()
            : null;
        if (reportedDirection !== 'forward' && reportedDirection !== 'backward') {
            const explicitRelocateSource = this._explicitRelocateHistoryMutationSource ?? null;
            const shouldRevealForExplicitRelocate = !!(
                EXPLICIT_RELOCATE_HISTORY_SOURCES.has(explicitRelocateSource)
                || this.isProcessingRelocateJump
                || this.pendingRelocateJump
            );
            if (shouldRevealForExplicitRelocate) {
                globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = false;
                globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = 0;
                this.setHideNavigationDueToScroll(false, 'relocate.explicit', {
                    reason: detail?.reason ?? null,
                    explicitRelocateSource,
                    sectionIndex: typeof detail?.sectionIndex === 'number' ? detail.sectionIndex : null,
                    pageNumber: this.rendererPageSnapshot?.current ?? null,
                    pageCount: this.rendererPageSnapshot?.total ?? null,
                });
                try {
                    window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
                        hideNavigationDueToScroll: false,
                        source: 'relocate.explicit',
                        reason: detail?.reason ?? null,
                        explicitRelocateSource,
                    });
                } catch (error) {
                }
            }
            return;
        }

        const direction = reportedDirection;
        const shouldHide = direction === 'forward';
        const now = Date.now();
        if (shouldHide) {
            const lastExplicitRevealAtMs = Number(globalThis.__manabiLastExplicitNavigationRevealAtMs || 0);
            const explicitRevealAgeMs = lastExplicitRevealAtMs > 0 ? now - lastExplicitRevealAtMs : Number.POSITIVE_INFINITY;
            if (explicitRevealAgeMs >= 0 && explicitRevealAgeMs < 900) {
                return;
            }
        }
        if (direction === 'forward') {
            globalThis.__manabiLastForwardPageTurnHideAtMs = now;
        } else if (direction === 'backward') {
            globalThis.__manabiLastBackwardPageTurnRevealAtMs = now;
        }
        if (shouldHide) {
            this.setHideNavigationDueToScroll(true, 'relocate.page-turn', {
                direction,
                reportedDirection,
                isRTL: this.isRTL,
                reason: detail?.reason ?? null,
                sectionIndex: typeof detail?.sectionIndex === 'number' ? detail.sectionIndex : null,
                pageNumber: this.rendererPageSnapshot?.current ?? null,
                pageCount: this.rendererPageSnapshot?.total ?? null,
            });
        } else {
        }
        try {
            window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
                hideNavigationDueToScroll: shouldHide,
                source: 'relocate.page-turn',
                direction,
                reportedDirection,
                isRTL: this.isRTL,
            });
        } catch (_error) {}
    }

    _updateRendererSnapshotFromDetail(detail) {
        const scrolled = detail?.scrolled;
        const pageNumber = typeof detail?.pageNumber === 'number' ? detail.pageNumber : null;
        const pageCount = typeof detail?.pageCount === 'number' ? detail.pageCount : null;
        // Only trust detail counts when renderer is paginated (scrolled === false) and counts are positive.
        if (scrolled === false && pageNumber != null && pageNumber > 0 && pageCount != null && pageCount > 0) {
            const normalized = this._normalizeRendererPageInfo(pageNumber, pageCount, this.getRenderer?.());
            this.rendererPageSnapshot = normalized;
            this.nativeOverlayPageSnapshot = {
                current: normalized.current,
                total: normalized.total,
                source: 'detail',
            };
            this._updateFallbackTotalPages(normalized.total);
            return normalized;
        }
        return null;
    }

    _fractionFromRendererSnapshot() {
        const snapshot = this.rendererPageSnapshot;
        if (snapshot?.scrolled !== false) return null;
        const current = typeof snapshot.current === 'number'
            ? Math.max(1, Math.round(snapshot.current))
            : null;
        const total = typeof snapshot.total === 'number'
            ? Math.max(1, Math.round(snapshot.total))
            : null;
        return this._scrubberFractionFromMetrics({
            current,
            total,
            fallbackFraction: null,
        });
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

        // Full/compact/hidden all show percent-only progress.
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
            }
        }
    }

    _postNativeOverlayState(source = 'refresh') {
        const percentLabel = this.navHiddenOverlay?.percent?.textContent
            || this.navPrimaryTextCompact?.textContent
            || this.navPrimaryTextFull?.textContent
            || this.latestPrimaryLabel
            || '';
        const hideNavigationDueToScroll = this.hideNavigationDueToScroll || this.navHidden;
        const titleLocationLabel = this.navTitleLocationLabel?.dataset?.titleLocationText || '';
        const titleLocationVisible = this.navTitleLocationLabel?.dataset?.visible === 'true' && !!titleLocationLabel;
        const bookTitleLabel = this.bookTitle || '';
        const pagesLeftLabel = this.lastPagesLeftLabel || '';
        const relocateBackEnabled = this._relocateButtonEnabled('back');
        const relocateForwardEnabled = this._relocateButtonEnabled('forward');
        const pageSnapshot = this.nativeOverlayPageSnapshot || this.rendererPageSnapshot || null;
        const currentPageNumber = typeof pageSnapshot?.current === 'number'
            ? pageSnapshot.current
            : null;
        const totalPages = typeof pageSnapshot?.total === 'number'
            ? pageSnapshot.total
            : null;
        try {
            window.webkit?.messageHandlers?.ebookNativeOverlayState?.postMessage?.({
                percentLabel,
                hideNavigationDueToScroll,
                titleLocationLabel,
                titleLocationVisible,
                bookTitleLabel,
                pagesLeftLabel,
                relocateBackEnabled,
                relocateForwardEnabled,
                currentPageNumber,
                totalPages,
                source,
            });
        } catch (_error) {}
    }

    _relocateButtonEnabled(direction) {
        if (this.hideNavigationDueToScroll || this.isProcessingRelocateJump) return false;
        return !!this.relocateStacks?.[direction]?.length;
    }

    _updateCompactPercent(detail) {
        const overlay = this.navHiddenOverlay?.percent;
        const fraction = this._fractionForPercent(detail, 'compact-percent');
        const hasValue = typeof fraction === 'number' && Number.isFinite(fraction);
        const percentText = hasValue ? this.formatPercent(Math.max(0, Math.min(1, fraction))) : '';
        if (overlay) {
            overlay.textContent = percentText;
            overlay.hidden = !hasValue;
            if (hasValue) overlay.removeAttribute('aria-hidden');
            else overlay.setAttribute('aria-hidden', 'true');
        }
        this._postNativeOverlayState('compact-percent');
    }

    _logPercentDecision(context, diagnostics) {
        const signature = JSON.stringify({
            context,
            selectedSource: diagnostics.selectedSource,
            selectedFraction: diagnostics.selectedFraction,
            detailFraction: diagnostics.detailFraction,
            lastRelocateFraction: diagnostics.lastRelocateFraction,
            currentLocationFraction: diagnostics.currentLocationFraction,
            lastLocationFraction: diagnostics.lastLocationFraction,
            requestedRestoreFraction: diagnostics.requestedRestoreFraction,
            lastScrubberFraction: diagnostics.lastScrubberFraction,
            snapshotCurrent: diagnostics.snapshotCurrent,
            snapshotTotal: diagnostics.snapshotTotal,
            snapshotScrolled: diagnostics.snapshotScrolled,
            snapshotFraction: diagnostics.snapshotFraction,
            descriptorCurrent: diagnostics.descriptorCurrent,
            descriptorTotal: diagnostics.descriptorTotal,
            derivedFraction: diagnostics.derivedFraction,
        });
        if (signature === this.lastPercentDecisionSignature) {
            return;
        }
        this.lastPercentDecisionSignature = signature;
        readerNavLoadLog('viewer.percent.decision', {
            context,
            selectedSource: diagnostics.selectedSource,
            selectedFraction: diagnostics.selectedFraction,
            detailFraction: diagnostics.detailFraction,
            lastRelocateFraction: diagnostics.lastRelocateFraction,
            currentLocationFraction: diagnostics.currentLocationFraction,
            lastLocationFraction: diagnostics.lastLocationFraction,
            requestedRestoreFraction: diagnostics.requestedRestoreFraction,
            lastScrubberFraction: diagnostics.lastScrubberFraction,
            snapshotCurrent: diagnostics.snapshotCurrent,
            snapshotTotal: diagnostics.snapshotTotal,
            snapshotScrolled: diagnostics.snapshotScrolled,
            snapshotFraction: diagnostics.snapshotFraction,
            descriptorCurrent: diagnostics.descriptorCurrent,
            descriptorTotal: diagnostics.descriptorTotal,
            derivedFraction: diagnostics.derivedFraction,
            oldSnapshotWouldWin: diagnostics.selectedSource !== 'rendererPageSnapshot'
                && typeof diagnostics.snapshotFraction === 'number',
        });
    }

    _fractionForPercent(detail, context = 'unknown') {
        const candidates = [
            { source: 'detail.fraction', value: detail?.fraction },
            { source: 'lastRelocateDetail.fraction', value: this.lastRelocateDetail?.fraction },
            { source: 'currentLocationDescriptor.fraction', value: this.currentLocationDescriptor?.fraction },
            { source: 'reader.view.lastLocation.fraction', value: globalThis.reader?.view?.lastLocation?.fraction },
            { source: '__manabiRequestedRestoreFraction', value: globalThis.__manabiRequestedRestoreFraction },
            { source: 'lastScrubberFraction', value: this.lastScrubberFraction },
        ];
        const snapshot = this.rendererPageSnapshot;
        const snapshotFraction = this._fractionFromRendererSnapshot();
        const descriptor = this._makeLocationDescriptor(detail)
            ?? this._cloneDescriptor(this.currentLocationDescriptor)
            ?? this._makeLocationDescriptor(this.lastRelocateDetail);
        const derived = this._scrubberFractionFromMetrics({
            current: typeof descriptor?.location?.current === 'number'
                ? Math.max(1, Math.round(descriptor.location.current) + 1)
                : null,
            total: typeof descriptor?.location?.total === 'number'
                ? Math.max(1, Math.round(descriptor.location.total))
                : null,
            fallbackFraction: null,
        });
        const diagnostics = {
            selectedSource: 'none',
            selectedFraction: null,
            detailFraction: typeof detail?.fraction === 'number' ? safeRound(detail.fraction, 6) : null,
            lastRelocateFraction: typeof this.lastRelocateDetail?.fraction === 'number' ? safeRound(this.lastRelocateDetail.fraction, 6) : null,
            currentLocationFraction: typeof this.currentLocationDescriptor?.fraction === 'number' ? safeRound(this.currentLocationDescriptor.fraction, 6) : null,
            lastLocationFraction: typeof globalThis.reader?.view?.lastLocation?.fraction === 'number' ? safeRound(globalThis.reader.view.lastLocation.fraction, 6) : null,
            requestedRestoreFraction: typeof globalThis.__manabiRequestedRestoreFraction === 'number' ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6) : null,
            lastScrubberFraction: typeof this.lastScrubberFraction === 'number' ? safeRound(this.lastScrubberFraction, 6) : null,
            snapshotCurrent: typeof snapshot?.current === 'number' ? snapshot.current : null,
            snapshotTotal: typeof snapshot?.total === 'number' ? snapshot.total : null,
            snapshotScrolled: typeof snapshot?.scrolled === 'boolean' ? snapshot.scrolled : null,
            snapshotFraction: typeof snapshotFraction === 'number' ? safeRound(snapshotFraction, 6) : null,
            descriptorCurrent: typeof descriptor?.location?.current === 'number' ? descriptor.location.current : null,
            descriptorTotal: typeof descriptor?.location?.total === 'number' ? descriptor.location.total : null,
            derivedFraction: typeof derived === 'number' ? safeRound(derived, 6) : null,
        };
        for (const candidate of candidates) {
            if (typeof candidate.value === 'number' && isFinite(candidate.value)) {
                const selected = Math.max(0, Math.min(1, candidate.value));
                diagnostics.selectedSource = candidate.source;
                diagnostics.selectedFraction = safeRound(selected, 6);
                this._logPercentDecision(context, diagnostics);
                return selected;
            }
        }
        if (typeof snapshotFraction === 'number' && isFinite(snapshotFraction)) {
            const selected = Math.max(0, Math.min(1, snapshotFraction));
            diagnostics.selectedSource = 'rendererPageSnapshot';
            diagnostics.selectedFraction = safeRound(selected, 6);
            this._logPercentDecision(context, diagnostics);
            return selected;
        }
        if (typeof derived === 'number' && isFinite(derived)) {
            const selected = Math.max(0, Math.min(1, derived));
            diagnostics.selectedSource = 'locationMetrics';
            diagnostics.selectedFraction = safeRound(selected, 6);
            this._logPercentDecision(context, diagnostics);
            return selected;
        }
        this._logPercentDecision(context, diagnostics);
        return null;
    }

    refreshAuxiliaryLayout() {
        this._requestAuxiliaryInsetsUpdate();
    }

    _applyRelocateButtonEdges() {
        this._requestAuxiliaryInsetsUpdate();
    }

    _requestAuxiliaryInsetsUpdate() {
        if (this.auxiliaryInsetsFrame) {
            return;
        }
        this.auxiliaryInsetsFrame = requestAnimationFrame(() => {
            this.auxiliaryInsetsFrame = 0;
            this._updateAuxiliaryInsets();
        });
    }

    _updateAuxiliaryInsets() {
        const startedAt = performance.now();
        const styleTarget = document.body ?? document.documentElement;
        if (!styleTarget?.style) return;
        const lookupPopoverPresented = document.body?.dataset?.mnbLookupPopoverPresented === 'true';
        const navRect = this.navBar?.getBoundingClientRect?.() ?? null;
        const pageReadButton = this.pageTrackingButtons?.querySelector?.('.page-read-button:not([hidden])')
            ?? this.pageTrackingButtons?.querySelector?.('.page-read-button')
            ?? null;
        const pageReadRect = pageReadButton?.getBoundingClientRect?.() ?? null;
        const leftInset = 0;
        const rightInset = 0;
        const nextState = {
            leftInset,
            rightInset,
        };
        const previousState = this.lastAuxiliaryInsetsState;
        const changed = !previousState
            || previousState.leftInset !== nextState.leftInset
            || previousState.rightInset !== nextState.rightInset;
        if (!changed) return;
        this.lastAuxiliaryInsetsState = nextState;
        styleTarget.style.setProperty('--nav-left-aux-inset', `${leftInset}px`);
        styleTarget.style.setProperty('--nav-right-aux-inset', `${rightInset}px`);
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
        return '';
    }

    getPrimaryDisplayLabel(detail) {
        const label = this.formatPrimaryLabel(detail, { allowRendererFallback: false });
        return label ?? '';
    }

    getPageEstimate(detail) {
        const descriptor = this._makeLocationDescriptor(detail);
        const current = typeof descriptor?.location?.current === 'number'
            ? Math.max(1, Math.round(descriptor.location.current) + 1)
            : null;
        const total = typeof descriptor?.location?.total === 'number'
            ? Math.max(1, Math.round(descriptor.location.total))
            : null;
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
            const descriptor = this._makeLocationDescriptor(detail);
            const computed = this.lastScrubberFraction
                ?? this._scrubberFractionFromMetrics({
                    current: typeof descriptor?.location?.current === 'number'
                        ? Math.max(1, Math.round(descriptor.location.current) + 1)
                        : null,
                    total: typeof descriptor?.location?.total === 'number'
                        ? Math.max(1, Math.round(descriptor.location.total))
                        : null,
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

        const {
            index: sectionIndex,
            source: sectionIndexSource,
            resolvedHref: resolvedSectionHref,
        } = this._resolveSectionIndex(detail);
        const fraction = this._fractionForPercent(detail, 'primary-label');
        if (typeof fraction === 'number' && Number.isFinite(fraction)) {
            const clampedFraction = Math.max(0, Math.min(1, fraction));
            const currentPercent = safeRound(clampedFraction * 100, 1);
            const label = this.formatPercent(clampedFraction);
            const source = 'percent';
            this.lastPrimaryLabelDiagnostics = {
                source,
                label,
                sectionIndex,
                totalPageCount: this.totalPageCount,
                currentPercent,
                fraction: safeRound(clampedFraction, 6),
            };
            this.latestPrimaryLabel = label;
            return label;
        }

        // Do not show guessed or fallback labels in the progress slot.
        this.latestPrimaryLabel = '';
        this.lastPrimaryLabelDiagnostics = {
            source: 'percent-pending',
            label: '',
            totalPageCount: this.totalPageCount,
            sectionIndex,
            sectionIndexSource,
            resolvedSectionHref,
        };
        return null;
    }

    _condensePrimaryLabel(label) {
        if (typeof label !== 'string') return '';
        return label.replace(/\s+/g, ' ').trim();
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
                return { index: candidate.value, source: candidate.source, resolvedHref: null };
            }
        }
        const hrefCandidates = [
            { source: 'renderer.contents[0].doc.body.dataset.mnbSourceHref', value: getRendererContentHref(renderer) },
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
                return { index: indexFromHref, source: candidate.source, resolvedHref: normalizedHref };
            }
        }
        const hasSectionMetadata = (this.sectionIndexByHref?.size ?? 0) > 0
            || (Array.isArray(this.navContext?.sections) && this.navContext.sections.length > 0);
        if (!hasSectionMetadata) {
            return { index: null, source: 'none', resolvedHref: null };
        }
        return { index: null, source: 'none', resolvedHref: null };
    }

    _isLastLinearSection(sectionIndex) {
        if (typeof sectionIndex !== 'number' || sectionIndex < 0) {
            return false;
        }
        const linearIndexes = Array.from(this.linearSectionIndexes ?? [])
            .filter(index => typeof index === 'number' && index >= 0)
            .sort((a, b) => a - b);
        if (linearIndexes.length > 0) {
            return !linearIndexes.some(index => index > sectionIndex);
        }
        const sections = Array.isArray(this.navContext?.sections) ? this.navContext.sections : [];
        if (sections.length === 0) {
            return false;
        }
        for (let index = sectionIndex + 1; index < sections.length; index += 1) {
            if (sections[index]?.linear !== 'no') {
                return false;
            }
        }
        return true;
    }
    
    _toggleCompletionStack(forceShow) {
        const shouldShow = typeof forceShow === 'boolean'
            ? forceShow
            : !!(this.navContext?.showingFinish || this.navContext?.showingRestart);
        const fadeTargets = [
            this.navSectionProgress?.leading,
            this.navSectionProgress?.trailing,
            this.navSectionProgress?.center,
        ].filter(Boolean);
        fadeTargets.forEach(el => {
            if (shouldShow) {
                el.classList.add('nav-fade-out');
            } else {
                el.classList.remove('nav-fade-out');
            }
        });
        this.navPrimaryText?.removeAttribute?.('aria-hidden');
        if (this.navPrimaryText) this.navPrimaryText.hidden = false;
        const descriptor = this.lastRelocateDetail || this.currentLocationDescriptor;
        this._updateCompactPercent(descriptor);
        this._requestAuxiliaryInsetsUpdate();
    }

    async _updateSectionProgress({ refreshSnapshot = true, source = 'refresh' } = {}) {
        const startedAt = performance.now();
        const requestToken = ++this.sectionProgressRequestToken;
        const leading = this.navSectionProgress?.leading;
        const trailing = this.navSectionProgress?.trailing;
        const center = this.navSectionProgress?.center;
        const setCenterPagesLeftVisible = (visible, label = '') => {
            if (!center) return;
            if (center.__pagesLeftFadeTimer) {
                clearTimeout(center.__pagesLeftFadeTimer);
                center.__pagesLeftFadeTimer = null;
            }
            if (visible) {
                center.hidden = false;
                center.textContent = label;
                if (center.dataset.pagesLeftVisible !== 'true') {
                    center.dataset.pagesLeftVisible = 'false';
                    void center.offsetWidth;
                    requestAnimationFrame(() => {
                        requestAnimationFrame(() => {
                            if (center.textContent === label) {
                                center.dataset.pagesLeftVisible = 'true';
                            }
                        });
                    });
                }
                return;
            }
            center.dataset.pagesLeftVisible = 'false';
            center.__pagesLeftFadeTimer = setTimeout(() => {
                if (center.dataset.pagesLeftVisible === 'false') {
                    center.textContent = '';
                    center.hidden = true;
                }
                center.__pagesLeftFadeTimer = null;
            }, 390);
        };
        if (leading) leading.hidden = true;
        if (trailing) trailing.hidden = true;
        try {
            const sectionResolution = this._resolveSectionIndex(this.lastRelocateDetail ?? this.currentLocationDescriptor ?? null);
            const result = await this._calculatePagesLeftInSection({ refreshSnapshot, requestToken, source });
            const pagesLeft = result?.pagesLeft ?? null;
            if (requestToken !== this.sectionProgressRequestToken) {
                return;
            }
            if (
                typeof result?.currentPageNumber === 'number'
                && result.currentPageNumber > 0
                && typeof result?.totalPages === 'number'
                && result.totalPages > 0
            ) {
                this.nativeOverlayPageSnapshot = {
                    current: result.currentPageNumber,
                    total: result.totalPages,
                    source: `section-progress:${result.source ?? source}`,
                };
            }
            const showingCompletion = this.navContext?.showingFinish || this.navContext?.showingRestart;
            if (this.hideNavigationDueToScroll || showingCompletion) {
                setCenterPagesLeftVisible(false);
                this._updateTitleLocationLabel({
                    pagesLeftVisible: false,
                    pagesLeftLabel: '',
                    source,
                });
                return;
            }
            if (sectionResolution.index == null) {
                setCenterPagesLeftVisible(false);
                this._updateTitleLocationLabel({
                    pagesLeftVisible: false,
                    pagesLeftLabel: '',
                    source,
                });
                return;
            }
            if (!pagesLeft || pagesLeft <= 0) {
                this.lastTerminalPagesLeftSection = sectionResolution.index;
                this.lastTerminalPagesLeftPageNumber = result?.currentPageNumber ?? null;
                setCenterPagesLeftVisible(false);
                this._updateTitleLocationLabel({
                    pagesLeftVisible: false,
                    pagesLeftLabel: '',
                    source,
                });
                return;
            }
            const isExplicitBackwardRelocate =
                source === 'relocate'
                && typeof this.lastRelocateDetail?.pageTurnDirection === 'string'
                && this.lastRelocateDetail.pageTurnDirection.toLowerCase() === 'backward';
            const movedBeforeTerminalPage =
                this.lastTerminalPagesLeftSection === sectionResolution.index
                && typeof this.lastTerminalPagesLeftPageNumber === 'number'
                && typeof result?.currentPageNumber === 'number'
                && result.currentPageNumber < this.lastTerminalPagesLeftPageNumber;
            if (
                this.lastTerminalPagesLeftSection === sectionResolution.index
                && !isExplicitBackwardRelocate
                && !movedBeforeTerminalPage
            ) {
                setCenterPagesLeftVisible(false);
                this._updateTitleLocationLabel({
                    pagesLeftVisible: false,
                    pagesLeftLabel: '',
                    source,
                });
                return;
            }
            if (
                isExplicitBackwardRelocate
                || movedBeforeTerminalPage
                || this.lastTerminalPagesLeftSection !== sectionResolution.index
            ) {
                this.lastTerminalPagesLeftSection = null;
                this.lastTerminalPagesLeftPageNumber = null;
            }
            const progressScope = this._isLastLinearSection(sectionResolution.index) ? 'book' : 'chapter';
            const label = pagesLeft === 1
                ? `1 page left in ${progressScope}`
                : `${pagesLeft} pages left in ${progressScope}`;
            setCenterPagesLeftVisible(false);
            this._updateTitleLocationLabel({
                pagesLeftVisible: true,
                pagesLeftLabel: label,
                source,
            });
        } catch (error) {
            console.error('Failed to update section progress', error);
        }
    }

    
    async _calculatePagesLeftInSection({ refreshSnapshot = true, requestToken = null, source = 'unknown' } = {}) {
        const detail = this.lastRelocateDetail;
        const sectionResolution = this._resolveSectionIndex(detail ?? this.currentLocationDescriptor ?? null);
        if (sectionResolution.index == null) {
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
        const liveSectionTotal = typeof this.rendererPageSnapshot?.total === 'number'
            ? this.rendererPageSnapshot.total
            : null;
        if (typeof liveSectionTotal === 'number' && liveSectionTotal > 0) {
            const pagesLeft = Math.max(0, liveSectionTotal - currentPageNumber);
            return {
                pagesLeft,
                source: 'snapshot',
                currentPageNumber,
                totalPages: liveSectionTotal,
                sectionIndex: sectionResolution.index,
            };
        }
        // Fallback to relocate detail when renderer snapshot is not currently available.
        if (detail?.scrolled === false) {
            const current = typeof detail.pageNumber === 'number' ? detail.pageNumber : null;
            const total = typeof detail.pageCount === 'number' ? detail.pageCount : null;
            if (current != null && current > 0 && total != null && total > 0) {
                const pagesLeft = Math.max(0, total - current);
                return {
                    pagesLeft,
                    source: 'detail',
                    currentPageNumber: current,
                    totalPages: total,
                    sectionIndex: sectionResolution.index,
                };
            }
        }
        const cachedSectionTotal = this.sectionPageCounts.get(sectionResolution.index);
        if (!(typeof cachedSectionTotal === 'number' && cachedSectionTotal > 0)) {
            return null;
        }
        const pagesLeft = Math.max(0, cachedSectionTotal - currentPageNumber);
        return {
            pagesLeft,
            source: 'cache',
            currentPageNumber,
            totalPages: cachedSectionTotal,
            sectionIndex: sectionResolution.index,
        };
    }
    
    _handleRelocateHistory(detail) {
        const descriptor = this._makeLocationDescriptor(detail);
        if (!descriptor) return;
        const reason = (detail?.reason || '').toLowerCase();
        const explicitMutationSource = this.#consumeExplicitRelocateHistoryMutation();
        const explicitMutate = EXPLICIT_RELOCATE_HISTORY_SOURCES.has(explicitMutationSource);
        const isImplicitProgressEvent = !reason || reason === 'page' || reason === 'navigation' || reason === 'live-scroll';
        const shouldMutateRelocateHistory = !!(
            (explicitMutate && !this.pendingScrubCommit)
            || this.isProcessingRelocateJump
            || this.pendingRelocateJump
        );
        if (!shouldMutateRelocateHistory && isImplicitProgressEvent) {
            this.currentLocationDescriptor = descriptor;
            this.pendingReleasedScrubDescriptor = null;
            this._maybeCommitPendingScrub(detail, descriptor);
            return;
        }
        const lastOrigin = this.scrubSession?.originDescriptor;
        // If the relocate matches the scrub origin immediately after a jump, don't clobber history yet.
        if (this.scrubSession?.pendingCommit && lastOrigin && this._isSameDescriptor(lastOrigin, descriptor)) {
            this.scrubSession.pendingCommit = false;
            this.currentLocationDescriptor = descriptor;
            return;
        }
        if (this.isProcessingRelocateJump) {
            this.currentLocationDescriptor = descriptor;
            this._finalizePendingRelocateJump(descriptor);
            if (this.isProcessingRelocateJump || this.pendingRelocateJump) {
                return;
            }
            // fall through to normal handling to capture subsequent movement if needed
        }
        const isRestoreInProgress = globalThis.__manabiRestoreInProgress === true;
        if (isRestoreInProgress) {
            if (this.relocateStacks.back.length || this.relocateStacks.forward.length) {
                this.relocateStacks.back.length = 0;
                this.relocateStacks.forward.length = 0;
            }
            this.currentLocationDescriptor = descriptor;
            this.pendingReleasedScrubDescriptor = null;
            this._updateRelocateButtons();
            return;
        }
        const liveScrollPhase = detail?.liveScrollPhase ?? null;
        const isLiveScrollReason = reason === 'live-scroll';
        const isJumpReason = isLiveScrollReason || explicitMutate || this.isProcessingRelocateJump || this.pendingRelocateJump;
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
        if (shouldMutateRelocateHistory && isJumpReason && descriptorChanged && !isLiveScrollReason) {
            if (!isScrubbing && previousDescriptor) {
                this._pushBackStack(previousDescriptor);
            }
        } else if (shouldMutateRelocateHistory && !isScrubbing && descriptorChanged) {
            this.relocateStacks.forward.length = 0;
        }
        this.currentLocationDescriptor = descriptor;
        this.pendingReleasedScrubDescriptor = null;
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
        }
        const fractionFromDescriptor = typeof descriptor?.fraction === 'number' ? descriptor.fraction : null;
        const previewFraction = fractionFromDescriptor ?? detailFraction ?? null;
        if (movedFromOrigin) {
            session.hasMoved = true;
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
        }
        this.relocateStacks.forward.length = 0;
        return { entry, index };
    }
    
    _makeLocationDescriptor(detail) {
        if (!detail) return null;
        const rawLocCurrent = typeof detail?.location?.current === 'number' ? detail.location.current : null;
        const locTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        const fraction = typeof detail.fraction === 'number' ? detail.fraction : null;
        const rendererCurrentIndex = (() => {
            try {
                const renderer = this.getRenderer?.();
                if (typeof renderer?.currentIndex === 'number') return renderer.currentIndex;
                return getPrimaryRendererContentIndex(renderer);
            } catch (_error) {
                return null;
            }
        })();
        const sectionIndex = typeof detail?.sectionIndex === 'number'
            ? Math.max(0, Math.round(detail.sectionIndex))
            : (typeof detail?.index === 'number'
                ? Math.max(0, Math.round(detail.index))
                : (typeof rendererCurrentIndex === 'number'
                    ? Math.max(0, Math.round(rendererCurrentIndex))
                    : (typeof this.lastSectionIndexSeen === 'number'
                        ? Math.max(0, Math.round(this.lastSectionIndexSeen))
                        : null)));
        const rendererSnapshotCurrent = typeof this.rendererPageSnapshot?.current === 'number'
            ? Math.max(1, Math.round(this.rendererPageSnapshot.current))
            : null;
        const rendererSnapshotTotal = typeof this.rendererPageSnapshot?.total === 'number'
            ? Math.max(1, Math.round(this.rendererPageSnapshot.total))
            : null;
        const localSectionIndex = rendererSnapshotCurrent != null ? rendererSnapshotCurrent - 1 : null;
        const derivedLocCurrent = deriveLocationIndexFromFraction(fraction, locTotal);
        let locCurrent = rawLocCurrent;
        if (derivedLocCurrent != null) {
            if (locCurrent == null) {
                locCurrent = derivedLocCurrent;
            } else {
                const drift = Math.abs(locCurrent - derivedLocCurrent);
                const staleAtStart = locCurrent === 0 && derivedLocCurrent > 0;
                if (drift > 1 || staleAtStart) {
                    locCurrent = derivedLocCurrent;
                }
            }
        }
        const location = (locCurrent != null || locTotal != null)
            ? { current: locCurrent, total: locTotal }
            : null;
        const locationTotalHint = locTotal != null ? locTotal : (this.lastKnownLocationTotal ?? null);
        const descriptor = {
            cfi: detail.cfi ?? null,
            fraction,
            sectionIndex,
            localSectionIndex,
            rendererTotal: rendererSnapshotTotal,
            pageItemKey: detail.pageItem ? ensurePageKey(detail.pageItem) : null,
            pageLabel: typeof detail.pageItem?.label === 'string' ? detail.pageItem.label : null,
            location,
            locationTotalHint,
        };
        return descriptor;
    }

    _rendererUsesRightToLeftPageOrder(renderer) {
        return !!(
            renderer?.bookDir === 'rtl'
            || renderer?.isRTL === true
            || this.isRTL === true
        );
    }

    _descriptorFromFraction(fraction) {
        if (typeof fraction !== 'number' || !isFinite(fraction)) return null;
        const locTotal = this.lastKnownLocationTotal ?? this.lastPrimaryLabelDiagnostics?.locationTotal ?? null;
        const hasTotal = typeof locTotal === 'number' && locTotal > 0;
        const clampedTotal = hasTotal ? Math.max(1, locTotal) : null;
        const location = hasTotal
            ? {
                total: clampedTotal,
                current: deriveLocationIndexFromFraction(fraction, clampedTotal),
            }
            : null;
        return {
            cfi: null,
            fraction,
            sectionIndex: null,
            localSectionIndex: null,
            rendererTotal: hasTotal ? clampedTotal : null,
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
            sectionIndex: typeof descriptor.sectionIndex === 'number' ? descriptor.sectionIndex : null,
            localSectionIndex: typeof descriptor.localSectionIndex === 'number' ? descriptor.localSectionIndex : null,
            rendererTotal: typeof descriptor.rendererTotal === 'number' ? descriptor.rendererTotal : null,
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
        const usesRightToLeftPageOrder = isPaginated && this._rendererUsesRightToLeftPageOrder(renderer);
        const snapshotBeforeAdjust = {
            rawPage,
            rawTotal,
            numericPage,
            numericTotal,
            totalBase: total,
            currentBase,
            clampedCurrent: current,
            scrolled,
            rtl: usesRightToLeftPageOrder,
        };
        const shouldAdjustForSentinels = MANABI_NAV_SENTINEL_ADJUST_ENABLED && isPaginated && total && total > 2;
        if (shouldAdjustForSentinels) {
            const textTotal = Math.max(1, total - 2); // strip lead/trail sentinels
            const rawTextCurrent = Math.max(1, Math.min(textTotal, current)); // clamp without subtracting so page 2 -> text page 2
            const textCurrent = usesRightToLeftPageOrder
                ? (textTotal - rawTextCurrent + 1)
                : rawTextCurrent;
            return {
                current: textCurrent,
                total: textTotal,
                rawCurrent: current,
                rawTotal: total,
                rawTextCurrent,
                rtl: usesRightToLeftPageOrder,
                scrolled,
            };
        }
        if (usesRightToLeftPageOrder && total && total > 1) {
            return {
                current: total - current + 1,
                total,
                rawCurrent: current,
                rawTotal: total,
                rtl: true,
                scrolled,
            };
        }
        return {
            current,
            total,
            rawCurrent: current,
            rawTotal: total,
            rtl: usesRightToLeftPageOrder,
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
            if (typeof renderer.pageMetrics === 'function') {
                const metrics = await renderer.pageMetrics();
                const normalized = this._normalizeRendererPageInfo(metrics?.page, metrics?.pages, renderer);
                if (!normalized) return null;
                this.rendererPageSnapshot = normalized;
                this.nativeOverlayPageSnapshot = {
                    current: normalized.current,
                    total: normalized.total,
                    source: 'renderer',
                };
                this._updateFallbackTotalPages(normalized.total);
                return normalized;
            }
            const [pageResult, pagesResult] = await Promise.allSettled([renderer.page(), renderer.pages()]);
            if (pageResult.status !== 'fulfilled' || pagesResult.status !== 'fulfilled') {
                return null;
            }
            const normalized = this._normalizeRendererPageInfo(pageResult.value, pagesResult.value, renderer);
            if (!normalized) return null;
            this.rendererPageSnapshot = normalized;
            this.nativeOverlayPageSnapshot = {
                current: normalized.current,
                total: normalized.total,
                source: 'renderer',
            };
            this._updateFallbackTotalPages(normalized.total);
            return normalized;
        } catch (_error) {
            return null;
        }
    }

    _scheduleRendererSnapshotRefresh(source = 'scheduled') {
        if (this.rendererSnapshotRefreshHandle) {
            cancelAnimationFrame(this.rendererSnapshotRefreshHandle);
            this.rendererSnapshotRefreshHandle = null;
        }
        this.rendererSnapshotRefreshHandle = requestAnimationFrame(async () => {
            this.rendererSnapshotRefreshHandle = null;
            try {
                await this._refreshRendererSnapshot();
                if (this.lastRelocateDetail) {
                    this._updatePrimaryLine(this.lastRelocateDetail);
                    await this._updateSectionProgress({ refreshSnapshot: false, source: `snapshot-refresh:${source}` });
                    this._updateRelocateButtons(`snapshot-refresh:${source}`);
                }
            } catch (_error) {
            }
        });
    }

    _isSameDescriptor(a, b) {
        if (!a || !b) return false;
        const aSectionIndex = typeof a.sectionIndex === 'number' ? a.sectionIndex : null;
        const bSectionIndex = typeof b.sectionIndex === 'number' ? b.sectionIndex : null;
        const aLocalSectionIndex = typeof a.localSectionIndex === 'number' ? a.localSectionIndex : null;
        const bLocalSectionIndex = typeof b.localSectionIndex === 'number' ? b.localSectionIndex : null;
        if (
            aSectionIndex != null && bSectionIndex != null
            && aLocalSectionIndex != null && bLocalSectionIndex != null
        ) {
            return aSectionIndex === bSectionIndex && aLocalSectionIndex === bLocalSectionIndex;
        }
        if (a.cfi && b.cfi && a.cfi === b.cfi) {
            if (typeof a.fraction === 'number' && typeof b.fraction === 'number') {
                return Math.abs(a.fraction - b.fraction) < FRACTION_EPSILON;
            }
            return true;
        }
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
            this.lastTotalPagesSnapshot = {
                source: best?.source ?? null,
                total: best?.total ?? null,
                candidateCount: summary.length,
            };
        }
        return best?.total ?? null;
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
        const descriptorFraction = typeof descriptor.fraction === 'number'
            ? Math.max(0, Math.min(1, descriptor.fraction))
            : null;
        if (descriptorFraction != null) {
            return this.formatPercent(descriptorFraction);
        }
        const currentPercent = this.lastPrimaryLabelDiagnostics?.currentPercent ?? null;
        if (typeof currentPercent === 'number') {
            return `${Number.isInteger(currentPercent) ? currentPercent : currentPercent.toFixed(1)}%`;
        }
        // No progress info; leave label empty.
        return '';
    }
    
    _isRelocateButtonVisible(direction) {
        return this._relocateButtonEnabled(direction);
    }

    _updateRelocateButtons(source = 'unknown') {
        const startedAt = performance.now();
        const backStack = this.relocateStacks.back;
        const forwardStack = this.relocateStacks.forward;
        const scrubbing = !!this.scrubSession?.active;
        const busy = !!this.isProcessingRelocateJump;
        const showBack = !this.hideNavigationDueToScroll && backStack.length > 0;
        const showForward = !this.hideNavigationDueToScroll && forwardStack.length > 0;
        const disableBack = busy || !showBack;
        const disableForward = busy || !showForward;
        const backLabelDescriptor = this._descriptorForRelocateLabel('back');
        const forwardLabelDescriptor = this._descriptorForRelocateLabel('forward');
        const backLabel = showBack ? this._labelForDescriptor(backLabelDescriptor) : '';
        const forwardLabel = showForward ? this._labelForDescriptor(forwardLabelDescriptor) : '';
        this._postNativeOverlayState(`relocate-buttons:${source}`);
        this._updateSectionProgress({ source: 'relocate-buttons' });
        if (this.previousRelocateVisibility.back !== showBack) {
            this.previousRelocateVisibility.back = showBack;
        }
        if (this.previousRelocateVisibility.forward !== showForward) {
            this.previousRelocateVisibility.forward = showForward;
        }
        this._requestAuxiliaryInsetsUpdate();
    }
    
    _serializeStack(stack) {
        if (!Array.isArray(stack) || !stack.length) {
            return [];
        }
        const LIMIT = 5;
        const total = stack.length;
        const tail = stack.slice(-LIMIT);
        return tail.map(function(entry, offset) {
            const index = total - tail.length + offset;
            return {
                index,
                fraction: typeof entry?.fraction === 'number' ? Number(entry.fraction.toFixed(6)) : null,
                pageKey: entry?.pageItemKey ?? null,
            };
        });
    }

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
            return false;
        }
        const shouldSkipForOrigin = this._isSameDescriptor(origin, effectiveDescriptor)
            && !(typeof releaseFraction === 'number' && typeof origin.fraction === 'number' && Math.abs(releaseFraction - origin.fraction) > FRACTION_EPSILON);
        if (shouldSkipForOrigin) {
            this.pendingScrubCommit = null;
            return false;
        }
        const result = this._pushBackStack(origin, { stripCFI: true });
        if (result?.entry) {
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
        this._updateRelocateButtons();
    }
    
    async _handleRelocateJump(direction) {

        const stack = this.relocateStacks?.[direction];
        if (!stack?.length) {
            return;
        }
        if (this.hideNavigationDueToScroll) {
            return;
        }
        if (this.pendingRelocateJump) {
            return;
        }
        const descriptor = this._cloneDescriptor(stack[stack.length - 1]);
        if (!descriptor) {
            return;
        }

        this.requestExplicitRelocateHistoryMutation?.('relocate-button');

        const preJumpDescriptor = this._cloneDescriptor(this.pendingReleasedScrubDescriptor)
            ?? this._cloneDescriptor(this.currentLocationDescriptor)
            ?? (this.lastRelocateDetail ? this._makeLocationDescriptor(this.lastRelocateDetail) : null);
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

        try {

            await this.onJumpRequest?.(descriptor);

        } catch (error) {
            console.error('Failed to navigate to saved location', error);
            this.pendingRelocateJump = null;
            this.isProcessingRelocateJump = false;
            this._updateRelocateButtons();
        } finally {
        }
    }
}
