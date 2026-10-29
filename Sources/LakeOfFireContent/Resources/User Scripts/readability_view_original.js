(function () {
    const wiredNodes = document.manabiViewOriginalLinksWired instanceof WeakSet
        ? document.manabiViewOriginalLinksWired : new WeakSet();
    document.manabiViewOriginalLinksWired = wiredNodes;

    function wireViewOriginal() {
        let nodes = document.body.getElementsByClassName('reader-view-original');
        for (let node of nodes) {
            if (!['A', 'BUTTON'].includes(node.tagName.toUpperCase()) || wiredNodes.has(node)) {
                continue;
            }
            wiredNodes.add(node);
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

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init, { once: true });
    } else {
        init();
    }
})();
