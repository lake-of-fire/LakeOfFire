export const ebookPageImageReadiness = media => {
    const picture = media?.localName === 'picture' ? media : null
    const image = picture ? picture.querySelector('img') : media
    if (picture && !image) return { state: 'failed' }
    if (image?.localName !== 'img') return null
    return {
        image,
        currentSrc: image.currentSrc,
        src: image.src,
        srcset: image.srcset,
        sizes: image.sizes,
        pictureSources: picture && JSON.stringify(Array.from(picture.children)
            .filter(child => child.localName === 'source')
            .map(({ media, type, srcset, sizes }) => [media, type, srcset, sizes])),
        state: !image.complete ? 'pending' : image.naturalWidth > 0 ? 'ready' : 'failed',
    }
}

export const sameEbookPageImageRequest = (left, right) =>
    !!left && !!right
    && left.image === right.image
    && left.currentSrc === right.currentSrc
    && left.src === right.src
    && left.srcset === right.srcset
    && left.sizes === right.sizes
    && left.pictureSources === right.pictureSources

export const waitForEbookPageImage = (image, signal, timeoutMs = 1500) => new Promise(resolve => {
    if (signal.aborted) {
        resolve('cancelled')
        return
    }
    let timer
    const finish = outcome => {
        clearTimeout(timer)
        image.removeEventListener('load', onChange)
        image.removeEventListener('error', onChange)
        signal.removeEventListener('abort', onAbort)
        resolve(outcome)
    }
    // Read browser state instead of treating every event from this element as
    // a receipt for the current request. The source may have changed meanwhile.
    const onChange = () => {
        if (image.complete) finish('settled')
    }
    const onAbort = () => finish('cancelled')
    image.addEventListener('load', onChange)
    image.addEventListener('error', onChange)
    signal.addEventListener('abort', onAbort)
    timer = setTimeout(() => finish('timeout'), timeoutMs)
    onChange()
})
