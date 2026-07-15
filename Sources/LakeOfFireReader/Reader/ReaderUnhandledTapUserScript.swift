import SwiftUIWebView
import WebKit

@MainActor
struct ReaderUnhandledTapUserScript {
    let userScript: WebViewUserScript
    
    init() {
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
            if (Math.hypot(x - entry.startX, y - entry.startY) <= MOVE_THRESHOLD) {
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
        if (Math.hypot(finalDX, finalDY) > MOVE_THRESHOLD) {
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
        const suppressUntil = Number(window.__manabiSuppressUnhandledTapHideNavigationUntil || 0);
        if (suppressUntil > Date.now()) {
            return;
        }
        const targetClosestSegment = event.target?.closest?.('mnb-seg')?.getAttribute?.('id') ?? null;
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
    const SCROLL_THRESHOLD = 24;
    function postHideNavigationForScroll(hidden, reason) {
        if (lastPostedScrollHidden.value === hidden) {
            return;
        }
        lastPostedScrollHidden.value = hidden;
        try {
            window.webkit.messageHandlers[handlerName].postMessage({
                frame: window === window.top ? 'top' : 'child',
                targetTag: null,
                targetClosestSegment: null,
                clientX: null,
                clientY: null,
                hideNavigationDueToScroll: hidden,
                reason
            });
        } catch (_error) {}
    }

    function handleDocumentScroll() {
        const currentX = window.scrollX || 0;
        const currentY = window.scrollY || 0;
        const dx = currentX - lastScrollPosition.x;
        const dy = currentY - lastScrollPosition.y;
        lastScrollPosition.x = currentX;
        lastScrollPosition.y = currentY;
        if (Math.abs(dx) > Math.abs(dy)) {
            return;
        }

        const delta = Math.abs(dy) >= Math.abs(dx) ? dy : dx;
        if (Math.abs(delta) < 0.5) {
            return;
        }
        accumulatedScroll.value += delta;
        if (accumulatedScroll.value > SCROLL_THRESHOLD) {
            postHideNavigationForScroll(true, 'documentScrollDown');
            accumulatedScroll.value = 0;
        } else if (accumulatedScroll.value < -SCROLL_THRESHOLD) {
            postHideNavigationForScroll(false, 'documentScrollUp');
            accumulatedScroll.value = 0;
        }
    }

    window.addEventListener('pointerdown', handlePointerDown, { capture: true, passive: true });
    window.addEventListener('pointermove', handlePointerMove, { capture: true, passive: true });
    window.addEventListener('pointerup', handlePointerUp, { capture: true, passive: true });
    window.addEventListener('pointercancel', handlePointerCancel, { capture: true, passive: true });
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
