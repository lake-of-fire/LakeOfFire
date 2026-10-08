(function () {
    const wiredNodes = new WeakMap();

    function wireViewOriginal() {
        let nodes = document.body.getElementsByClassName('reader-view-original');
        for (let node of nodes) {
            if (!['A', 'BUTTON'].includes(node.tagName.toUpperCase()) || wiredNodes.has(node)) {
                continue;
            }
            wiredNodes.set(node, true); // Mark the node as wired
            node.addEventListener('click', (e) => {
                e.preventDefault();
                window.webkit.messageHandlers.showOriginal.postMessage({});
            }, false);
        }
    }

    function init() {
        wireViewOriginal();
        new MutationObserver(() => wireViewOriginal())
            .observe(document, { childList: true, subtree: true, attributes: false });
    }

    if (document.readyState === 'complete') {
        init();
    } else {
        document.addEventListener('DOMContentLoaded', init);
    }
})();
