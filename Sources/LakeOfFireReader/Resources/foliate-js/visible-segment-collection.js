const ELEMENT_NODE = 1;
const SHOW_ELEMENT = 1;
const FILTER_ACCEPT = 1;
const FILTER_REJECT = 2;
const FILTER_SKIP = 3;
const DOCUMENT_POSITION_PRECEDING = 2;
const DOCUMENT_POSITION_FOLLOWING = 4;

export const compareSegmentNodesInDocumentOrder = (first, second) => {
    if (!first || !second || first === second) return 0;
    const position = first.compareDocumentPosition?.(second) ?? 0;
    if (position & DOCUMENT_POSITION_PRECEDING) return 1;
    if (position & DOCUMENT_POSITION_FOLLOWING) return -1;
    return 0;
};

export const collectSegmentNodesInVisibleRange = (visibleRange, segmentSelector = 'mnb-seg') => {
    const doc = visibleRange?.commonAncestorContainer?.ownerDocument
        || visibleRange?.startContainer?.ownerDocument
        || visibleRange?.endContainer?.ownerDocument
        || null;
    const commonAncestor = visibleRange?.commonAncestorContainer ?? null;
    const root = commonAncestor?.nodeType === ELEMENT_NODE
        ? commonAncestor
        : commonAncestor?.parentElement;
    if (!doc || !root) return null;

    const nodes = [];
    const appendSegment = (node) => {
        if (node?.nodeType === ELEMENT_NODE && node.matches?.(segmentSelector)) nodes.push(node);
    };
    appendSegment(root);
    const walker = doc.createTreeWalker(root, SHOW_ELEMENT, {
        acceptNode(node) {
            if (node === root) return FILTER_SKIP;
            try {
                return visibleRange.intersectsNode(node) ? FILTER_ACCEPT : FILTER_REJECT;
            } catch (_error) {
                return FILTER_REJECT;
            }
        },
    });
    let current = walker.nextNode();
    while (current) {
        appendSegment(current);
        current = walker.nextNode();
    }
    return nodes.length > 0 ? nodes : null;
};

export const collectViewportSampleSegmentNodes = (doc, visibleBounds, {
    sampleDensity = 'normal',
    segmentSelector = 'mnb-seg',
    sentenceSelector = 'mnb-sen',
} = {}) => {
    if (!doc || !visibleBounds || typeof doc.elementFromPoint !== 'function') return null;
    const isMinimal = sampleDensity === 'minimal';
    const xFractions = isMinimal ? [0.25, 0.5, 0.75] : [0.12, 0.25, 0.38, 0.5, 0.62, 0.75, 0.88];
    const yFractions = isMinimal ? [0.2, 0.5, 0.8] : [0.12, 0.28, 0.44, 0.6, 0.76, 0.92];
    const candidateLimit = isMinimal ? 8 : 144;
    const left = Math.max(0, Math.floor(visibleBounds.left || 0));
    const top = Math.max(0, Math.floor(visibleBounds.top || 0));
    const right = Math.max(left, Math.ceil(visibleBounds.right || 0));
    const bottom = Math.max(top, Math.ceil(visibleBounds.bottom || 0));
    if (right <= left || bottom <= top) return null;

    const candidates = [];
    const seen = new Set();
    const append = (node) => {
        const segment = node?.matches?.(segmentSelector) ? node : node?.closest?.(segmentSelector);
        if (!segment || seen.has(segment) || candidates.length >= candidateLimit) return;
        seen.add(segment);
        candidates.push(segment);
    };
    for (const yFraction of yFractions) {
        const y = Math.min(bottom - 1, Math.max(top, Math.round(top + (bottom - top) * yFraction)));
        for (const xFraction of xFractions) {
            const x = Math.min(right - 1, Math.max(left, Math.round(left + (right - left) * xFraction)));
            append(doc.elementFromPoint(x, y));
            let caretNode = null;
            try {
                caretNode = doc.caretPositionFromPoint?.(x, y)?.offsetNode ?? null;
            } catch (_error) {}
            if (!caretNode) {
                try {
                    caretNode = doc.caretRangeFromPoint?.(x, y)?.startContainer ?? null;
                } catch (_error) {}
            }
            append(caretNode?.nodeType === ELEMENT_NODE ? caretNode : caretNode?.parentElement);
        }
    }

    if (!isMinimal) {
        for (const sampledSegment of [...candidates]) {
            if (doc.body && typeof doc.createTreeWalker === 'function') {
                const walker = doc.createTreeWalker(doc.body, SHOW_ELEMENT, {
                    acceptNode: node => node.matches?.(segmentSelector) ? FILTER_ACCEPT : FILTER_SKIP,
                });
                walker.currentNode = sampledSegment;
                for (let offset = 0; offset < 4; offset += 1) {
                    const previous = walker.previousNode();
                    if (!previous) break;
                    append(previous);
                }
                walker.currentNode = sampledSegment;
                for (let offset = 0; offset < 4; offset += 1) {
                    const next = walker.nextNode();
                    if (!next) break;
                    append(next);
                }
                continue;
            }

            const sentence = sampledSegment.closest?.(sentenceSelector);
            const sentenceSegments = Array.from(sentence?.children ?? [])
                .filter((node) => node.matches?.(segmentSelector));
            const sampledIndex = sentenceSegments.indexOf(sampledSegment);
            if (sampledIndex < 0) continue;
            const start = Math.max(0, sampledIndex - 4);
            const end = Math.min(sentenceSegments.length - 1, sampledIndex + 4);
            for (let index = start; index <= end; index += 1) append(sentenceSegments[index]);
        }
    }
    candidates.sort(compareSegmentNodesInDocumentOrder);
    return candidates.length > 0 ? candidates : null;
};
