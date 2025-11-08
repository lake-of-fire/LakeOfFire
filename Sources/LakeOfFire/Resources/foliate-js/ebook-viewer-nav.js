const MAX_RELOCATE_STACK = 50;

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
        this.navSecondaryText = document.getElementById('nav-secondary-text');
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
        this.secondarySides = {
            leading: document.getElementById('nav-secondary-leading'),
            trailing: document.getElementById('nav-secondary-trailing'),
        };
        this.completionStack = document.getElementById('completion-stack');
        
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
        
        this.navRelocateButtons.back?.addEventListener('click', () => this.#handleRelocateJump('back'));
        this.navRelocateButtons.forward?.addEventListener('click', () => this.#handleRelocateJump('forward'));
        this.#positionCompletionStack();
        this.#updateRelocateButtons();
    }
    
    setIsRTL(isRTL) {
        this.isRTL = !!isRTL;
        this.#positionCompletionStack();
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
        if (this.lastRelocateDetail) {
            this.#updatePrimaryLine(this.lastRelocateDetail);
        }
    }
    
    setNavContext(context) {
        this.navContext = context ?? null;
        this.#updateSectionProgress();
        this.#updateRelocateButtons();
    }
    
    setHideNavigationDueToScroll(shouldHide) {
        this.hideNavigationDueToScroll = !!shouldHide;
        this.navBar?.classList.toggle('nav-hidden-due-to-scroll', this.hideNavigationDueToScroll);
        if (this.lastRelocateDetail) {
            this.#updatePrimaryLine(this.lastRelocateDetail);
        }
        this.#updateRelocateButtons();
    }
    
    async handleRelocate(detail) {
        if (!detail) return;
        this.lastRelocateDetail = detail;
        this.#updatePrimaryLine(detail);
        await this.#updateSecondaryLine(detail);
        this.#handleRelocateHistory(detail);
        this.#updateRelocateButtons();
    }
    
    #positionCompletionStack() {
        if (!this.completionStack) return;
        const sideKey = this.isRTL ? 'leading' : 'trailing';
        const container = this.secondarySides?.[sideKey];
        if (!container || container.contains(this.completionStack)) return;
        if (sideKey === 'leading') {
            const reference = this.navSectionProgress?.leading;
            if (reference) {
                reference.after(this.completionStack);
            } else {
                container.appendChild(this.completionStack);
            }
        } else {
            const forwardButton = this.navRelocateButtons?.forward;
            if (forwardButton && forwardButton.parentElement === container) {
                container.insertBefore(this.completionStack, forwardButton);
            } else {
                container.appendChild(this.completionStack);
            }
        }
    }
    
    #updatePrimaryLine(detail) {
        if (!this.navPrimaryText) return;
        const {
            pageItem,
            fraction,
            location
        } = detail ?? {};
        const pageIndex = this.#resolvePageIndex(pageItem);
        const hasTotal = this.totalPageCount > 0;
        let primary = '';
        if (this.hideNavigationDueToScroll) {
            if (pageIndex != null) {
                primary = `Page ${pageIndex + 1}`;
            } else if (pageItem?.label) {
                primary = `Page ${pageItem.label}`;
            }
        } else if (hasTotal && pageIndex != null) {
            primary = `${pageIndex + 1} of ${this.totalPageCount}`;
        } else if (hasTotal && pageItem?.label) {
            primary = `${pageItem.label} of ${this.totalPageCount}`;
        }
        if (!primary && pageItem?.label) {
            primary = `Page ${pageItem.label}`;
        }
        if (!primary) {
            const approxIndex = this.#pageIndexFromFraction(fraction);
            if (approxIndex != null && hasTotal) {
                primary = `${approxIndex + 1} of ${this.totalPageCount}`;
            }
        }
        if (!primary && typeof fraction === 'number') {
            primary = this.formatPercent(fraction);
        }
        if (!primary && location?.current != null && location?.total != null) {
            primary = `Loc ${location.current} of ${location.total}`;
        }
        this.navPrimaryText.textContent = primary ?? '';
    }
    
    async #updateSecondaryLine(detail) {
        if (this.navSecondaryText) {
            this.navSecondaryText.textContent = '';
        }
        await this.#updateSectionProgress();
    }
    
    async #updateSectionProgress() {
        const leading = this.navSectionProgress?.leading;
        const trailing = this.navSectionProgress?.trailing;
        if (leading) leading.hidden = true;
        if (trailing) trailing.hidden = true;
        try {
            const showingCompletion = this.navContext?.showingFinish || this.navContext?.showingRestart;
            if (this.hideNavigationDueToScroll || showingCompletion) return;
            const targetKey = this.isRTL ? 'leading' : 'trailing';
            const relocateDirection = targetKey === 'leading' ? 'back' : 'forward';
            if (this.#isRelocateButtonVisible(relocateDirection)) return;
            const pagesLeft = await this.#calculatePagesLeftInSection();
            if (!pagesLeft || pagesLeft <= 0) return;
            const target = this.navSectionProgress?.[targetKey];
            if (!target) return;
            const label = pagesLeft === 1 ? '1 page left in chapter' : `${pagesLeft} pages left in chapter`;
            target.textContent = label;
            target.hidden = false;
        } catch (error) {
            console.error('Failed to update section progress', error);
        }
    }
    
    async #calculatePagesLeftInSection() {
        const renderer = this.getRenderer?.();
        if (!renderer || typeof renderer.pages !== 'function' || typeof renderer.page !== 'function') return null;
        const totalPages = await renderer.pages();
        if (!totalPages || totalPages <= 2) return null;
        const currentRaw = await renderer.page();
        const totalTextPages = Math.max(0, totalPages - 2);
        const currentTextPage = Math.max(1, Math.min(totalTextPages, currentRaw ?? 1));
        return Math.max(0, totalTextPages - currentTextPage);
    }
    
    #handleRelocateHistory(detail) {
        const descriptor = this.#makeLocationDescriptor(detail);
        if (!descriptor) return;
        if (this.isProcessingRelocateJump) {
            this.currentLocationDescriptor = descriptor;
            return;
        }
        const reason = (detail?.reason || '').toLowerCase();
        const isJumpReason = reason === 'live-scroll' || reason === 'scroll-to';
        if (isJumpReason && this.currentLocationDescriptor && !this.#isSameDescriptor(this.currentLocationDescriptor, descriptor)) {
            const backStack = this.relocateStacks.back;
            backStack.push(this.currentLocationDescriptor);
            if (backStack.length > MAX_RELOCATE_STACK) {
                backStack.shift();
            }
            this.relocateStacks.forward.length = 0;
        }
        this.currentLocationDescriptor = descriptor;
    }
    
    #makeLocationDescriptor(detail) {
        if (!detail) return null;
        return {
            cfi: detail.cfi ?? null,
            fraction: typeof detail.fraction === 'number' ? detail.fraction : null,
            pageItemKey: detail.pageItem ? ensurePageKey(detail.pageItem) : null,
        };
    }
    
    #isSameDescriptor(a, b) {
        if (!a || !b) return false;
        if (a.cfi && b.cfi) return a.cfi === b.cfi;
        if (typeof a.fraction === 'number' && typeof b.fraction === 'number') {
            return Math.abs(a.fraction - b.fraction) < 0.0001;
        }
        return false;
    }
    
    #resolvePageIndex(pageItem) {
        if (!pageItem || !this.pageTargetIndexByKey) return null;
        const key = ensurePageKey(pageItem);
        if (!key) return null;
        return this.pageTargetIndexByKey.get(key) ?? null;
    }
    
    #pageIndexFromFraction(fraction) {
        if (typeof fraction !== 'number' || !this.totalPageCount) return null;
        const approx = Math.round(fraction * (this.totalPageCount - 1));
        return Math.max(0, Math.min(this.totalPageCount - 1, approx));
    }
    
    #labelForDescriptor(descriptor) {
        if (!descriptor) return '';
        if (descriptor.pageItemKey && this.pageTargetIndexByKey?.has(descriptor.pageItemKey)) {
            return String((this.pageTargetIndexByKey.get(descriptor.pageItemKey) ?? 0) + 1);
        }
        const indexFromFraction = this.#pageIndexFromFraction(descriptor.fraction);
        if (indexFromFraction != null) {
            return String(indexFromFraction + 1);
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
        const showBack = !this.hideNavigationDueToScroll && backStack.length > 0;
        const showForward = !this.hideNavigationDueToScroll && forwardStack.length > 0;
        if (backBtn) {
            backBtn.hidden = !showBack;
            backBtn.disabled = !showBack;
            if (!showBack) {
                backBtn.setAttribute('aria-hidden', 'true');
            } else {
                backBtn.removeAttribute('aria-hidden');
            }
        }
        if (forwardBtn) {
            forwardBtn.hidden = !showForward;
            forwardBtn.disabled = !showForward;
            if (!showForward) {
                forwardBtn.setAttribute('aria-hidden', 'true');
            } else {
                forwardBtn.removeAttribute('aria-hidden');
            }
        }
        if (this.navRelocateLabels?.back) {
            this.navRelocateLabels.back.textContent = showBack ? this.#labelForDescriptor(backStack[backStack.length - 1] ?? null) : '';
        }
        if (this.navRelocateLabels?.forward) {
            this.navRelocateLabels.forward.textContent = showForward ? this.#labelForDescriptor(forwardStack[forwardStack.length - 1] ?? null) : '';
        }
        this.#updateSectionProgress();
    }
    
    async #handleRelocateJump(direction) {
        const stack = this.relocateStacks?.[direction];
        if (!stack?.length || this.hideNavigationDueToScroll) return;
        const descriptor = stack.pop();
        const opposite = direction === 'back' ? 'forward' : 'back';
        const oppositeStack = this.relocateStacks?.[opposite];
        if (oppositeStack && this.currentLocationDescriptor) {
            oppositeStack.push(this.currentLocationDescriptor);
            if (oppositeStack.length > MAX_RELOCATE_STACK) {
                oppositeStack.shift();
            }
        }
        if (!descriptor) return;
        this.isProcessingRelocateJump = true;
        try {
            await this.onJumpRequest?.(descriptor);
        } catch (error) {
            console.error('Failed to navigate to saved location', error);
        } finally {
            this.isProcessingRelocateJump = false;
            this.#updateRelocateButtons();
        }
    }
}
