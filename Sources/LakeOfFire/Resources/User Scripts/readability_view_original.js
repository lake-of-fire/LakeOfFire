(function () {
    const wiredNodes = new WeakMap();
    
    function wireViewOriginal() {
        let nodes = document.body.getElementsByClassName('reader-view-original');
        for (let node of nodes) {
            if (node.tagName.toUpperCase() !== 'A' || wiredNodes.has(node)) {
                continue;
            }
            wiredNodes.set(node, true); // Mark the node as wired
            node.addEventListener('click', (e) => {
                e.preventDefault();
                window.webkit.messageHandlers.showOriginal.postMessage({});
            }, false);
        }
    }
    
    function onReadabilityModeDetected() {
        // Wire the existing nodes and start observing for new ones
        wireViewOriginal();
        new MutationObserver(() => {
            wireViewOriginal();
        }).observe(document, { childList: true, subtree: true, attributes: false });
    }
    
    function init() {
        if (document.body?.classList.contains('readability-mode')) {
            onReadabilityModeDetected();
        } else {
            const observer = new MutationObserver(() => {
                if (document.body?.classList.contains('readability-mode')) {
                    observer.disconnect();
                    onReadabilityModeDetected();
                }
            });
            observer.observe(document.body, { attributes: true, attributeFilter: ['class'] });
        }
    }
    
    if (document.readyState === 'complete') {
        init();
    } else {
        document.addEventListener('DOMContentLoaded', init);
    }
})();
