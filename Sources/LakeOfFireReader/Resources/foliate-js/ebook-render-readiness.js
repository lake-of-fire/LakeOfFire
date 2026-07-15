const singleMediaSelector = 'img, svg, image, picture, video, object';

const visibleJapaneseTextState = visibleSegmentsResult => {
    let visibleSegmentCount = 0;
    for (const item of visibleSegmentsResult?.visibleSegments ?? []) {
        if ((item?.node?.textContent ?? '').trim().length > 0) {
            visibleSegmentCount += 1;
        }
    }
    return {
        hasVisibleJapaneseText: visibleSegmentCount > 0,
        visibleSegmentCount,
        observedSegmentCount: visibleSegmentsResult?.totalSegmentCount ?? 0,
    };
};

const mediaReadinessState = media => {
    if (!media) return 'absent';
    if (media.error) return 'failed';
    const tagName = media.tagName?.toLowerCase?.() ?? '';
    if (tagName === 'img' && media.complete === false) return 'pending';
    if (tagName === 'video' && Number(media.readyState ?? 0) === 0) return 'pending';
    return 'settled';
};

export const classifyEbookRenderReadiness = (doc, visibleSegmentsResult = null) => {
    const textState = visibleJapaneseTextState(visibleSegmentsResult);
    if (textState.hasVisibleJapaneseText) {
        return {
            ...textState,
            outcome: 'ready',
            reason: 'visible-japanese-text',
            hasRenderableContent: true,
            hasVisibleSingleMedia: false,
        };
    }

    const body = doc?.body ?? null;
    if (!body) {
        return {
            ...textState,
            outcome: 'pending',
            reason: 'missing-body',
            hasRenderableContent: false,
            hasVisibleSingleMedia: false,
        };
    }
    const isSingleMediaDocument = body.classList
        ?.contains?.('reader-is-single-media-element-without-text') === true;
    const media = isSingleMediaDocument ? body.querySelector?.(singleMediaSelector) ?? null : null;
    const mediaState = mediaReadinessState(media);
    if (mediaState === 'failed') {
        return {
            ...textState,
            outcome: 'error',
            reason: 'single-media-failed',
            hasRenderableContent: false,
            hasVisibleSingleMedia: false,
        };
    }
    if (mediaState === 'pending' || doc.readyState === 'loading') {
        return {
            ...textState,
            outcome: 'pending',
            reason: mediaState === 'pending' ? 'single-media-pending' : 'document-loading',
            hasRenderableContent: false,
            hasVisibleSingleMedia: false,
        };
    }

    let hasVisibleSingleMedia = false;
    if (media) {
        const rect = media.getBoundingClientRect?.() ?? null;
        const style = doc.defaultView?.getComputedStyle?.(media) ?? null;
        hasVisibleSingleMedia = !!rect
            && rect.width > 1
            && rect.height > 1
            && style?.display !== 'none'
            && style?.visibility !== 'hidden'
            && Number.parseFloat(style?.opacity ?? '1') > 0.01;
    }
    return {
        ...textState,
        outcome: hasVisibleSingleMedia ? 'ready' : 'empty',
        reason: hasVisibleSingleMedia ? 'visible-single-media' : 'no-visible-renderable-content',
        hasRenderableContent: hasVisibleSingleMedia,
        hasVisibleSingleMedia,
    };
};

export const waitForEbookRenderReadinessSignal = (doc, timeoutMs = 1500) => {
    const body = doc?.body ?? null;
    const media = body?.querySelector?.(singleMediaSelector) ?? null;
    const target = media?.addEventListener ? media : (doc?.addEventListener ? doc : null);
    if (!target) return Promise.resolve('unavailable');

    return new Promise(resolve => {
        let settled = false;
        let timeoutHandle = null;
        const eventNames = target === media
            ? ['load', 'error', 'loadeddata', 'canplay']
            : ['DOMContentLoaded'];
        const finish = reason => {
            if (settled) return;
            settled = true;
            if (timeoutHandle !== null) clearTimeout(timeoutHandle);
            for (const eventName of eventNames) {
                target.removeEventListener?.(eventName, onEvent);
            }
            resolve(reason);
        };
        const onEvent = event => finish(event?.type ?? 'event');
        for (const eventName of eventNames) {
            target.addEventListener(eventName, onEvent, { once: true });
        }
        if (
            (media && mediaReadinessState(media) !== 'pending')
            || (!media && doc?.readyState !== 'loading')
        ) {
            finish('already-settled');
            return;
        }
        timeoutHandle = setTimeout(() => finish('timeout'), Math.max(0, timeoutMs));
    });
};

export class EbookRenderReadinessCoordinator {
    #generation = 0;
    #expectedIdentity = null;
    #terminalOutcome = null;

    begin(expectedIdentity = null) {
        this.#generation += 1;
        this.#expectedIdentity = expectedIdentity;
        this.#terminalOutcome = null;
        return this.#generation;
    }

    validate(generation, identity = null) {
        if (generation !== this.#generation) {
            return { accepted: false, reason: 'stale-generation' };
        }
        if (this.#expectedIdentity !== null && identity !== this.#expectedIdentity) {
            return { accepted: false, reason: 'unexpected-identity' };
        }
        return { accepted: true, reason: 'current' };
    }

    settle(generation, readiness, identity = null) {
        const validation = this.validate(generation, identity);
        if (!validation.accepted) return validation;
        if (this.#terminalOutcome) {
            return { accepted: false, reason: 'already-terminal', outcome: this.#terminalOutcome };
        }
        if (readiness?.outcome === 'pending') {
            return { accepted: false, reason: 'pending' };
        }
        this.#terminalOutcome = readiness?.outcome ?? 'error';
        return { accepted: true, reason: readiness?.reason ?? 'unspecified', outcome: this.#terminalOutcome };
    }
}
