const packageEntryPathPrefixes = ['/entry-source/', '/entry-session/'];
const mediaSourceSelector = 'audio[src], video[src], audio source[src], video source[src]';

export const isPackageMediaURL = value => {
    try {
        const url = new URL(value);
        return url.protocol === 'ebook:' && url.hostname === 'ebook'
            && url.username === '' && url.password === '' && url.port === ''
            && packageEntryPathPrefixes.some(prefix => url.pathname.startsWith(prefix));
    } catch {
        return false;
    }
};

export const hydratePackageMedia = async ({
    document: doc = globalThis.document,
    fetch: fetchResource = globalThis.fetch,
    createObjectURL = blob => globalThis.URL.createObjectURL(blob),
    revokeObjectURL = url => globalThis.URL.revokeObjectURL(url),
    addPageHideListener = listener =>
        globalThis.addEventListener?.('pagehide', listener, { once: true }),
} = {}) => {
    if (!doc?.querySelectorAll || !fetchResource) return [];

    const objectURLPromises = new Map();
    const ownedObjectURLs = new Set();
    let closed = false;
    addPageHideListener?.(() => {
        closed = true;
        for (const objectURL of ownedObjectURLs) revokeObjectURL(objectURL);
        ownedObjectURLs.clear();
    });
    const objectURLFor = sourceURL => {
        const url = new URL(sourceURL);
        const fragment = url.hash;
        url.hash = '';
        const resourceURL = url.href;
        let promise = objectURLPromises.get(resourceURL);
        if (!promise) {
            promise = fetchResource(resourceURL)
                .then(response => {
                    if (!response.ok) {
                        throw new Error(`Failed to load ebook media: ${response.status}`);
                    }
                    return response.blob();
                })
                .then(blob => {
                    if (closed) return null;
                    const objectURL = createObjectURL(blob);
                    ownedObjectURLs.add(objectURL);
                    if (closed) {
                        ownedObjectURLs.delete(objectURL);
                        revokeObjectURL(objectURL);
                        return null;
                    }
                    return objectURL;
                });
            objectURLPromises.set(resourceURL, promise);
        }
        return promise.then(objectURL => objectURL === null ? null : `${objectURL}${fragment}`);
    };

    const mediaOwner = element => element.matches?.('audio, video')
        ? element : element.closest?.('audio, video');
    const workItems = Array.from(doc.querySelectorAll(mediaSourceSelector), element => {
        const sourceURL = element.src;
        if (!isPackageMediaURL(sourceURL)) return { element, sourceURL };
        const owningMedia = mediaOwner(element);
        return { element, sourceURL, owningMedia };
    });
    const ownerGroups = new Map();
    for (const item of workItems) {
        if (!item.owningMedia) continue;
        let group = ownerGroups.get(item.owningMedia);
        if (!group) {
            group = { remaining: 0, published: new Map(), expectedSource: item.owningMedia.src };
            ownerGroups.set(item.owningMedia, group);
        }
        group.remaining++;
        item.ownerGroup = group;
    }

    const outcomes = await Promise.allSettled(workItems.map(async item => {
        try {
            if (!isPackageMediaURL(item.sourceURL)) return false;
            const objectURL = await objectURLFor(item.sourceURL);
            // A closed/replaced document or explicitly changed media source does
            // not inherit a late response from its former package capability.
            if (closed || objectURL === null || item.element.isConnected === false
                || item.element.src !== item.sourceURL
                || mediaOwner(item.element) !== item.owningMedia
                || (item.ownerGroup && (item.owningMedia.isConnected === false
                    || item.owningMedia.src !== item.ownerGroup.expectedSource))) return false;
            item.element.src = objectURL;
            if (item.ownerGroup) {
                item.ownerGroup.published.set(item.element, objectURL);
                if (item.element === item.owningMedia) item.ownerGroup.expectedSource = objectURL;
            }
            return true;
        } finally {
            if (item.ownerGroup) {
                item.ownerGroup.remaining--;
                const group = item.ownerGroup;
                // A settled sibling must not reload a replaced or detached owner,
                // or media whose hydrated sources have since moved/changed.
                if (group.remaining === 0 && !closed
                    && item.owningMedia.isConnected !== false
                    && item.owningMedia.src === group.expectedSource
                    && Array.from(group.published).some(([element, url]) =>
                        element.isConnected !== false && element.src === url
                        && mediaOwner(element) === item.owningMedia)) {
                    item.owningMedia.load?.();
                }
            }
        }
    }));

    const failures = outcomes.filter(outcome => outcome.status === 'rejected');
    if (failures.length === 1) throw failures[0].reason;
    if (failures.length > 1) throw new AggregateError(
        failures.map(outcome => outcome.reason), 'Failed to hydrate ebook package media');
    return outcomes.map(outcome => outcome.value);
};

export const installPackageMediaHydration = ({
    document: doc = globalThis.document,
    ...options
} = {}) => {
    if (doc?.documentElement?.dataset) {
        doc.documentElement.dataset.mnbPackageMediaState = 'loading';
    }
    return hydratePackageMedia({ document: doc, ...options }).then(results => {
        if (doc?.documentElement?.dataset) {
            doc.documentElement.dataset.mnbPackageMediaState = 'ready';
        }
        return results;
    }).catch(error => {
        if (doc?.documentElement?.dataset) {
            doc.documentElement.dataset.mnbPackageMediaState = 'error';
        }
        throw error;
    });
};

if (globalThis.document) {
    const hydration = installPackageMediaHydration();
    globalThis.manabiEbookPackageMediaHydration = hydration;
    hydration.catch(error => {
        console.error('Failed to hydrate ebook package media', error);
    });
}
