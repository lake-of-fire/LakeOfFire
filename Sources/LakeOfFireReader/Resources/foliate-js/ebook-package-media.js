const packageEntryPathPrefix = '/entry-source/';
const mediaSourceSelector = 'audio[src], video[src], audio source[src], video source[src]';

const mediaOwnerFor = element => element.matches?.('audio, video')
    ? element
    : element.closest?.('audio, video')

const captureMediaSourceSelection = element => {
    const document = element.ownerDocument
    let expectedSource = element.src
    let changed = false
    const Observer = document?.defaultView?.MutationObserver
    const observer = Observer ? new Observer(() => { changed = true }) : null
    const observe = () => observer?.observe(element, { attributes: true, attributeFilter: ['src'] })
    observe()

    return {
        isCurrent() {
            // Include queued mutations even if the observer has not run yet.
            // String equality alone would admit a source changed A -> B -> A.
            if (observer?.takeRecords().length) changed = true
            return !changed && element.isConnected !== false
                && element.ownerDocument === document
                && element.src === expectedSource
        },
        publish(objectURL) {
            // This operation's own src write is the only permitted mutation.
            observer?.disconnect()
            expectedSource = objectURL
            element.src = objectURL
            observe()
        },
        dispose() { observer?.disconnect() },
    }
}

export const isPackageMediaURL = value => {
    try {
        const url = new URL(value);
        return url.protocol === 'ebook:' && url.hostname === 'ebook'
            && url.username === '' && url.password === '' && url.port === ''
            && url.pathname.startsWith(packageEntryPathPrefix)
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
    const sourceSelections = new Map()
    const selectionFor = element => {
        let selection = sourceSelections.get(element)
        if (!selection) {
            selection = captureMediaSourceSelection(element)
            sourceSelections.set(element, selection)
        }
        return selection
    }
    let closed = false
    addPageHideListener?.(() => {
        closed = true
        for (const selection of sourceSelections.values()) selection.dispose()
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
                    if (closed) return null
                    const objectURL = createObjectURL(blob);
                    ownedObjectURLs.add(objectURL);
                    if (closed) {
                        ownedObjectURLs.delete(objectURL)
                        revokeObjectURL(objectURL)
                        return null
                    }
                    return objectURL;
                });
            objectURLPromises.set(resourceURL, promise);
        }
        return promise.then(objectURL => objectURL === null ? null : `${objectURL}${fragment}`)
    };

    const mediaElements = new Map()
    const pending = Array.from(doc.querySelectorAll(mediaSourceSelector), async element => {
        const sourceURL = element.src;
        if (!isPackageMediaURL(sourceURL)) return false;
        const selection = selectionFor(element)
        const media = mediaOwnerFor(element)
        const mediaSelection = media ? selectionFor(media) : null
        const owner = {
            isCurrent: () => selection.isCurrent() && (!mediaSelection || mediaSelection.isCurrent())
                && mediaOwnerFor(element) === media,
        }
        const objectURL = await objectURLFor(sourceURL)
        if (closed || objectURL === null || !owner.isCurrent()) return false
        selection.publish(objectURL)
        if (media) {
            const owners = mediaElements.get(media) ?? []
            owners.push(owner)
            mediaElements.set(media, owners)
        }
        return true
    })

    try {
        const results = await Promise.all(pending)
        // Another resource can keep the batch pending after an earlier src
        // publication. Revalidate each owner before invoking its media element.
        for (const [media, owners] of mediaElements) {
            if (!closed && owners.some(owner => owner.isCurrent())) media.load?.()
        }
        return results
    } finally {
        // Promise.all can reject while peer fetches still own pending sources.
        // Keep their observations until they settle (or pagehide retires them).
        void Promise.allSettled(pending).then(() => {
            for (const selection of sourceSelections.values()) selection.dispose()
            sourceSelections.clear()
        })
    }
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
