import SwiftUIWebView
import WebKit

@MainActor
struct ReaderUnhandledTapUserScript {
    let userScript: WebViewUserScript
    
    init(observesTouchScrollEnd: Bool? = nil) {
#if os(iOS)
        let requiresUserScrollIntent = true
        let supportsTouchScrollEnd: Bool
        if #available(iOS 26.2, *) {
            supportsTouchScrollEnd = true
        } else {
            supportsTouchScrollEnd = false
        }
#else
        let requiresUserScrollIntent = false
        let supportsTouchScrollEnd = false
#endif
        let observesTouchScrollEnd = observesTouchScrollEnd ?? supportsTouchScrollEnd
        let contents = """
(function() {
    const handlerName = 'swiftUIWebViewUnhandledTap';
    if (!window.webkit?.messageHandlers?.[handlerName]) {
        return;
    }

    const interactiveSelectors = '#nav-bar,#progress-wrapper,.nav-relocate-button,.nav-section-progress,a[href],button,input,textarea,select,summary,label,[role="button"],[role="link"],[role="menuitem"],[role="tab"],[contenteditable="true"]';
    const MOVE_THRESHOLD = 8;
    const LONG_PRESS_THRESHOLD_MS = 450;
    const activePointers = new Map();

    function isEbookPage() {
        try {
            if (window.manabi_isEbook === true) {
                return true;
            }
            if (window.location?.origin?.startsWith('ebook://')) {
                return true;
            }
            return window.top?.location?.origin?.startsWith('ebook://') === true;
        } catch (_error) {
            return window.manabi_isEbook === true
                || window.location?.origin?.startsWith('ebook://') === true;
        }
    }

    if (isEbookPage()) {
        return;
    }

    function selectionText() {
        const sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) {
            return '';
        }
        return sel.toString() || '';
    }

    function elementLooksInteractive(element) {
        if (!element || !(element instanceof Element)) {
            return false;
        }
        if (element.matches(interactiveSelectors) || element.closest(interactiveSelectors)) {
            return true;
        }
        if (element.hasAttribute('onclick')) {
            return true;
        }
        if (element.tabIndex >= 0 && element.getAttribute('tabindex') !== '-1') {
            return true;
        }
        return false;
    }

    function pathContainsInteractive(path) {
        if (!Array.isArray(path)) return false;
        return path.some(node => elementLooksInteractive(node));
    }

    function registerPointer(event) {
        const path = event.composedPath ? event.composedPath() : [];
        if (pathContainsInteractive(path)) {
            return;
        }
        activePointers.set(event.pointerId, {
            startX: event.clientX ?? 0,
            startY: event.clientY ?? 0,
            moved: false,
            suppressUnhandledTap: false,
            startTime: performance.now(),
            startSelection: selectionText(),
        });
    }

    window.__manabiSuppressCurrentUnhandledTapHideNavigation = function(clientX, clientY) {
        const x = Number(clientX);
        const y = Number(clientY);
        if (!Number.isFinite(x) || !Number.isFinite(y)) {
            return false;
        }
        for (const entry of activePointers.values()) {
            const distance = Math.hypot(x - entry.startX, y - entry.startY);
            if (distance <= MOVE_THRESHOLD) {
                entry.suppressUnhandledTap = true;
                return true;
            }
        }
        return false;
    };

    window.__manabiSuppressActiveUnhandledTapHideNavigation = function() {
        let markedCount = 0;
        for (const entry of activePointers.values()) {
            entry.suppressUnhandledTap = true;
            markedCount += 1;
        }
        return markedCount > 0;
    };

    function handlePointerDown(event) {
        if (event.defaultPrevented || event.button > 0) {
            return;
        }
        registerPointer(event);
    }

    function handlePointerMove(event) {
        const entry = activePointers.get(event.pointerId);
        if (!entry) return;
        const dx = (event.clientX ?? 0) - entry.startX;
        const dy = (event.clientY ?? 0) - entry.startY;
        if (Math.hypot(dx, dy) > MOVE_THRESHOLD) {
            entry.moved = true;
        }
    }

    function handlePointerUp(event) {
        const entry = activePointers.get(event.pointerId);
        activePointers.delete(event.pointerId);
        if (!entry || event.defaultPrevented) {
            return;
        }
        const duration = performance.now() - entry.startTime;
        const finalDX = (event.clientX ?? entry.startX) - entry.startX;
        const finalDY = (event.clientY ?? entry.startY) - entry.startY;
        const finalDistance = Math.hypot(finalDX, finalDY);
        if (finalDistance > MOVE_THRESHOLD) {
            entry.moved = true;
        }
        const newSelection = selectionText();
        const selectionChanged = newSelection.length > 0 && newSelection !== entry.startSelection;
        if (entry.moved || duration > LONG_PRESS_THRESHOLD_MS || selectionChanged) {
            return;
        }
        if (entry.suppressUnhandledTap === true) {
            return;
        }
        const targetClosestSegment = event.target?.closest?.('m-m')?.getAttribute?.('id') ?? null;
        if (targetClosestSegment) {
            return;
        }
        window.webkit.messageHandlers[handlerName].postMessage({
            frame: window === window.top ? 'top' : 'child',
            targetTag: event.target?.tagName?.toLowerCase?.() ?? null,
            targetClosestSegment,
            clientX: event.clientX ?? null,
            clientY: event.clientY ?? null,
            reason: 'pointerUpBlankTap'
        });
    }

    function handlePointerCancel(event) {
        activePointers.delete(event.pointerId);
    }

    let lastScrollPosition = { x: window.scrollX || 0, y: window.scrollY || 0 };
    let accumulatedScroll = { value: 0 };
    let lastPostedScrollHidden = { value: null };
    const requiresUserScrollIntent = \(requiresUserScrollIntent ? "true" : "false");
    let scrollNavigationEnabled = !requiresUserScrollIntent;
    let lastTrustedScrollInputAt = { value: 0 };
    const scrollInputEvents = ['touchmove', 'wheel', 'keydown'];
    const SCROLL_THRESHOLD = 24;
    const USER_SCROLL_INTENT_LIFETIME_MS = 1500;
    let lastTrustedScrollInputType = null;
    let lastPostWasTouchDownwardHide = false;
    const observesTouchScrollEnd = \(observesTouchScrollEnd ? "true" : "false") && window === window.top;
    let pendingTouchDownwardHide = false;
    let bottomRevealAwaitingDeparture = false;
    let observedBottomDeparture = false;
    function documentScrollHeight() {
        return (document.scrollingElement || document.documentElement)?.scrollHeight || 0;
    }
    function maximumScrollY() {
        return Math.max(0, documentScrollHeight() - window.innerHeight);
    }
    let lastMaximumScrollY = maximumScrollY();
    let lastViewportHeight = window.innerHeight;
    let lastDocumentScrollHeight = documentScrollHeight();
    function isScrollInput(event) {
        if (event.isTrusted !== true || event.defaultPrevented) return false;
        switch (event.type) {
        case 'touchmove':
            return event.touches?.length === 1;
        case 'wheel':
            return !event.ctrlKey && Math.abs(event.deltaY) > 0;
        case 'keydown':
            return ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(event.key)
                && !elementLooksInteractive(event.target);
        default:
            return false;
        }
    }

    function enableScrollNavigation(event) {
        if (!isScrollInput(event)) return;
        lastTrustedScrollInputAt.value = Date.now();
        lastTrustedScrollInputType = event.type === 'touchmove' ? 'touch'
            : event.type === 'wheel' ? 'wheel' : 'keyboard';
        if (lastTrustedScrollInputType !== 'touch') {
            pendingTouchDownwardHide = false;
        }
        if (lastPostWasTouchDownwardHide && lastTrustedScrollInputType !== 'touch') {
            // A native host may ignore the touch hint and keep its sheet open.
            // A following wheel or key scroll gets its own visibility decision.
            lastPostedScrollHidden.value = null;
            lastPostWasTouchDownwardHide = false;
        }
        if (!scrollNavigationEnabled) {
            scrollNavigationEnabled = true;
            lastScrollPosition.x = window.scrollX || 0;
            lastScrollPosition.y = window.scrollY || 0;
            lastMaximumScrollY = maximumScrollY();
            lastViewportHeight = window.innerHeight;
            lastDocumentScrollHeight = documentScrollHeight();
            accumulatedScroll.value = 0;
        }
    }

    function postHideNavigationForScroll(hidden, reason) {
        const bottomArrival = reason === 'documentScrollBottom';
        const observedDeparture = reason === 'documentScrollUpFromObservedBottom';
        const bottomDeparture = observedDeparture
            || (reason === 'documentScrollUp' && bottomRevealAwaitingDeparture);
        const touchDrivenDownwardHide = hidden && reason === 'documentScrollDown'
            && requiresUserScrollIntent && lastTrustedScrollInputType === 'touch'
            && lastPostedScrollHidden.value !== hidden;
        const visibilityHandler = window.webkit.messageHandlers.ebookNavigationVisibility;
        if (window === window.top && visibilityHandler
            && (bottomArrival || bottomDeparture || touchDrivenDownwardHide)) {
            try {
                visibilityHandler.postMessage({
                    hideNavigationDueToScroll: hidden,
                    reason,
                    source: 'nonEBookDocumentScroll',
                    direction: bottomDeparture ? 'backward' : 'forward',
                    inputType: touchDrivenDownwardHide ? 'touch' : null
                });
                bottomRevealAwaitingDeparture = bottomArrival;
                lastPostedScrollHidden.value = hidden;
                lastPostWasTouchDownwardHide = touchDrivenDownwardHide;
                return;
            } catch (_error) {}
        }
        if (lastPostedScrollHidden.value === hidden) {
            return;
        }
        lastPostedScrollHidden.value = hidden;
        lastPostWasTouchDownwardHide = false;
        try {
            window.webkit.messageHandlers[handlerName].postMessage({
                frame: window === window.top ? 'top' : 'child',
                targetTag: null,
                targetClosestSegment: null,
                clientX: null,
                clientY: null,
                hideNavigationDueToScroll: hidden,
                reason: observedDeparture ? 'documentScrollUp' : reason
            });
        } catch (_error) {}
    }

    function handleDocumentScroll() {
        const currentX = window.scrollX || 0;
        const maximumY = maximumScrollY();
        const viewportHeight = window.innerHeight;
        const scrollHeight = documentScrollHeight();
        const rangeChanged = Math.abs(maximumY - lastMaximumScrollY) > 0.5
            || Math.abs(viewportHeight - lastViewportHeight) > 0.5
            || Math.abs(scrollHeight - lastDocumentScrollHeight) > 0.5;
        const currentY = Math.min(maximumY, Math.max(0, window.scrollY || 0));
        const previousY = Math.min(maximumY, Math.max(0, lastScrollPosition.y));
        const dx = currentX - lastScrollPosition.x;
        const dy = currentY - previousY;
        lastScrollPosition.x = currentX;
        lastScrollPosition.y = currentY;
        lastMaximumScrollY = maximumY;
        lastViewportHeight = viewportHeight;
        lastDocumentScrollHeight = scrollHeight;
        if (rangeChanged) {
            pendingTouchDownwardHide = false;
            observedBottomDeparture = false;
            accumulatedScroll.value = 0;
            return;
        }
        if (!scrollNavigationEnabled) {
            accumulatedScroll.value = 0;
            return;
        }
        if (requiresUserScrollIntent
            && Date.now() - lastTrustedScrollInputAt.value > USER_SCROLL_INTENT_LIFETIME_MS) {
            observedBottomDeparture = false;
            accumulatedScroll.value = 0;
            return;
        }
        if (Math.abs(dx) > Math.abs(dy)) {
            return;
        }

        const bottomThreshold = Math.max(0, maximumY - 2);
        const crossedOutOfBottom = maximumY > 0 && previousY >= bottomThreshold
            && currentY < bottomThreshold && dy < -0.5;
        if (maximumY > 0 && previousY < bottomThreshold
            && currentY >= bottomThreshold && dy > 0) {
            pendingTouchDownwardHide = false;
            observedBottomDeparture = false;
            postHideNavigationForScroll(false, 'documentScrollBottom');
            accumulatedScroll.value = 0;
            return;
        }
        if (bottomRevealAwaitingDeparture && dy < -0.5) {
            accumulatedScroll.value += dy;
            if (crossedOutOfBottom || accumulatedScroll.value < -SCROLL_THRESHOLD) {
                pendingTouchDownwardHide = false;
                postHideNavigationForScroll(false, 'documentScrollUp');
                accumulatedScroll.value = 0;
            }
            return;
        }
        if (crossedOutOfBottom && requiresUserScrollIntent) {
            // Native media reconciliation can promote a restored bottom
            // position without a WebKit bottom-arrival message.
            observedBottomDeparture = true;
        }
        const delta = Math.abs(dy) >= Math.abs(dx) ? dy : dx;
        if (Math.abs(delta) < 0.5) {
            return;
        }
        accumulatedScroll.value += delta;
        if (accumulatedScroll.value > SCROLL_THRESHOLD) {
            // A real downward reading gesture leaves the bottom-reveal
            // interval. The next upward gesture is an ordinary visibility
            // change, even when a layout resize rebased the scroll range.
            bottomRevealAwaitingDeparture = false;
            observedBottomDeparture = false;
            if (observesTouchScrollEnd && lastTrustedScrollInputType === 'touch') {
                pendingTouchDownwardHide = true;
            }
            // Hosts that do not opt in still use the ordinary live hide hint.
            postHideNavigationForScroll(true, 'documentScrollDown');
            accumulatedScroll.value = 0;
        } else if (accumulatedScroll.value < -SCROLL_THRESHOLD) {
            pendingTouchDownwardHide = false;
            const reason = observedBottomDeparture
                ? 'documentScrollUpFromObservedBottom' : 'documentScrollUp';
            observedBottomDeparture = false;
            postHideNavigationForScroll(false, reason);
            accumulatedScroll.value = 0;
        }
    }

    function resetPendingTouchHide(event) {
        if (event.isTrusted) {
            pendingTouchDownwardHide = false;
        }
    }

    function handleDocumentScrollEnd(event) {
        if (event.target !== document || !event.isTrusted || !pendingTouchDownwardHide) return;
        pendingTouchDownwardHide = false;
        const maximumY = maximumScrollY();
        if (maximumY <= 2 || (window.scrollY || 0) >= maximumY - 2) return;
        window.webkit.messageHandlers.ebookNavigationVisibility?.postMessage({
            hideNavigationDueToScroll: true,
            reason: 'documentTouchScrollSettled',
            source: 'nonEBookDocumentScroll',
            direction: 'forward',
            inputType: 'touch'
        });
    }

    if (observesTouchScrollEnd) {
        window.addEventListener('touchstart', resetPendingTouchHide, { passive: true });
        window.addEventListener('scrollend', handleDocumentScrollEnd, { capture: true, passive: true });
    }

    window.addEventListener('pointerdown', handlePointerDown, { capture: true, passive: true });
    window.addEventListener('pointermove', handlePointerMove, { capture: true, passive: true });
    window.addEventListener('pointerup', handlePointerUp, { capture: true, passive: true });
    window.addEventListener('pointercancel', handlePointerCancel, { capture: true, passive: true });
    for (const type of scrollInputEvents) {
        // Bubble after target handlers so canceled input is excluded.
        window.addEventListener(type, enableScrollNavigation, { passive: true });
    }
    window.addEventListener('scroll', handleDocumentScroll, { capture: true, passive: true });
})();
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .page
        )
    }
}
