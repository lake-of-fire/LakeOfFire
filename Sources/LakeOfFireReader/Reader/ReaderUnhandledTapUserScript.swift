import SwiftUIWebView
import WebKit

@MainActor
struct ReaderUnhandledTapUserScript {
    let userScript: WebViewUserScript
    
    init() {
#if os(iOS)
        let requiresUserScrollIntent = true
#else
        let requiresUserScrollIntent = false
#endif
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

    let accumulatedScroll = { value: 0 }
    let lastPostedScrollHidden = { value: null }
    const requiresUserScrollIntent = \(requiresUserScrollIntent ? "true" : "false")
    let scrollNavigationEnabled = !requiresUserScrollIntent
    let lastTrustedScrollInputAt = { value: 0 }
    const scrollInputEvents = ['touchmove', 'wheel', 'keydown']
    const SCROLL_THRESHOLD = 24
    const USER_SCROLL_INTENT_LIFETIME_MS = 1500
    let bottomRevealAwaitingDeparture = false
    let observedBottomDeparture = false

    function readScrollGeometry() {
        // Use the native coordinator's resolver so initial/restored geometry and
        // DOM arrival/departure agree about vertical writing and page overrides.
        const semantics = \(WebViewNavigationScrollSemantics.javaScript)
        const horizontal = semantics.axis === 'horizontal'
        const root = document.scrollingElement || document.documentElement
        const viewport = horizontal
            ? root?.clientWidth || window.innerWidth
            : root?.clientHeight || window.innerHeight
        const extent = (horizontal ? root?.scrollWidth : root?.scrollHeight) || 0
        const maximum = Math.max(0, extent - viewport)
        const forwardSign = horizontal ? semantics.horizontalForwardSign : 1
        // CSSOM's horizontal viewport origin is zero: vertical-rl advances
        // toward negative scrollX, while vertical-lr advances toward positive X.
        const offset = horizontal ? (window.scrollX || 0) * forwardSign : window.scrollY || 0
        return {
            axis: semantics.axis,
            forwardSign,
            viewport,
            extent,
            maximum,
            position: Math.min(maximum, Math.max(0, offset)),
            crossPosition: horizontal ? window.scrollY || 0 : window.scrollX || 0
        }
    }

    let lastScrollGeometry = readScrollGeometry()

    function isScrollInput(event) {
        if (event.isTrusted !== true || event.defaultPrevented) return false
        switch (event.type) {
        case 'touchmove':
            return event.touches?.length === 1
        case 'wheel':
            return !event.ctrlKey && (Math.abs(event.deltaY || 0) > 0
                || (readScrollGeometry().axis === 'horizontal' && Math.abs(event.deltaX || 0) > 0))
        case 'keydown':
            return !elementLooksInteractive(event.target)
                && (['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(event.key)
                    || (readScrollGeometry().axis === 'horizontal'
                        && ['ArrowLeft', 'ArrowRight'].includes(event.key)))
        default:
            return false
        }
    }

    function enableScrollNavigation(event) {
        if (!isScrollInput(event)) return
        lastTrustedScrollInputAt.value = Date.now()
        if (!scrollNavigationEnabled) {
            scrollNavigationEnabled = true
            lastScrollGeometry = readScrollGeometry()
            accumulatedScroll.value = 0
        }
    }

    function postHideNavigationForScroll(hidden, reason) {
        const bottomArrival = reason === 'documentScrollBottom'
        const observedDeparture = reason === 'documentScrollUpFromObservedBottom'
        const bottomDeparture = observedDeparture
            || (reason === 'documentScrollUp' && bottomRevealAwaitingDeparture)
        const visibilityHandler = window.webkit.messageHandlers.ebookNavigationVisibility
        if (window === window.top && visibilityHandler && (bottomArrival || bottomDeparture)) {
            try {
                visibilityHandler.postMessage({
                    hideNavigationDueToScroll: hidden,
                    reason,
                    source: 'nonEBookDocumentScroll',
                    direction: bottomDeparture ? 'backward' : 'forward'
                })
                bottomRevealAwaitingDeparture = bottomArrival
                lastPostedScrollHidden.value = hidden
                return
            } catch (_error) {}
        }
        if (lastPostedScrollHidden.value === hidden) {
            return
        }
        lastPostedScrollHidden.value = hidden
        try {
            window.webkit.messageHandlers[handlerName].postMessage({
                frame: window === window.top ? 'top' : 'child',
                targetTag: null,
                targetClosestSegment: null,
                clientX: null,
                clientY: null,
                hideNavigationDueToScroll: hidden,
                reason: observedDeparture ? 'documentScrollUp' : reason
            })
        } catch (_error) {}
    }

    function handleDocumentScroll() {
        const geometry = readScrollGeometry()
        const semanticsChanged = geometry.axis !== lastScrollGeometry.axis
            || geometry.forwardSign !== lastScrollGeometry.forwardSign
        const rangeChanged = semanticsChanged
            || Math.abs(geometry.maximum - lastScrollGeometry.maximum) > 0.5
            || Math.abs(geometry.viewport - lastScrollGeometry.viewport) > 0.5
            || Math.abs(geometry.extent - lastScrollGeometry.extent) > 0.5
        const previousPosition = Math.min(geometry.maximum, lastScrollGeometry.position)
        const delta = geometry.position - previousPosition
        const crossDelta = geometry.crossPosition - lastScrollGeometry.crossPosition
        lastScrollGeometry = geometry
        if (rangeChanged) {
            if (semanticsChanged) bottomRevealAwaitingDeparture = false
            observedBottomDeparture = false
            accumulatedScroll.value = 0
            return
        }
        if (!scrollNavigationEnabled) {
            accumulatedScroll.value = 0
            return
        }
        if (requiresUserScrollIntent
            && Date.now() - lastTrustedScrollInputAt.value > USER_SCROLL_INTENT_LIFETIME_MS) {
            observedBottomDeparture = false
            accumulatedScroll.value = 0
            return
        }
        if (Math.abs(crossDelta) > Math.abs(delta)) {
            return
        }

        const bottomThreshold = Math.max(0, geometry.maximum - 2)
        const crossedOutOfBottom = geometry.maximum > 0 && previousPosition >= bottomThreshold
            && geometry.position < bottomThreshold && delta < -0.5
        if (geometry.maximum > 0 && previousPosition < bottomThreshold
            && geometry.position >= bottomThreshold && delta > 0) {
            observedBottomDeparture = false
            postHideNavigationForScroll(false, 'documentScrollBottom')
            accumulatedScroll.value = 0
            return
        }
        if (bottomRevealAwaitingDeparture && delta < -0.5) {
            accumulatedScroll.value += delta
            if (crossedOutOfBottom || accumulatedScroll.value < -SCROLL_THRESHOLD) {
                postHideNavigationForScroll(false, 'documentScrollUp')
                accumulatedScroll.value = 0
            }
            return
        }
        if (crossedOutOfBottom && requiresUserScrollIntent) {
            // Native media reconciliation can promote a restored bottom
            // position without a WebKit bottom-arrival message.
            observedBottomDeparture = true
        }
        if (Math.abs(delta) < 0.5) {
            return
        }
        accumulatedScroll.value += delta
        if (accumulatedScroll.value > SCROLL_THRESHOLD) {
            // A real forward reading gesture leaves the bottom-reveal
            // interval. The next backward gesture is an ordinary visibility
            // change, even when a layout resize rebased the scroll range.
            bottomRevealAwaitingDeparture = false
            observedBottomDeparture = false
            postHideNavigationForScroll(true, 'documentScrollDown')
            accumulatedScroll.value = 0
        } else if (accumulatedScroll.value < -SCROLL_THRESHOLD) {
            const reason = observedBottomDeparture
                ? 'documentScrollUpFromObservedBottom' : 'documentScrollUp'
            observedBottomDeparture = false
            postHideNavigationForScroll(false, reason)
            accumulatedScroll.value = 0
        }
    }

    window.addEventListener('pointerdown', handlePointerDown, { capture: true, passive: true });
    window.addEventListener('pointermove', handlePointerMove, { capture: true, passive: true });
    window.addEventListener('pointerup', handlePointerUp, { capture: true, passive: true });
    window.addEventListener('pointercancel', handlePointerCancel, { capture: true, passive: true });
    for (const type of scrollInputEvents) {
        // Bubble after target handlers so canceled input is excluded.
        window.addEventListener(type, enableScrollNavigation, { passive: true })
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
