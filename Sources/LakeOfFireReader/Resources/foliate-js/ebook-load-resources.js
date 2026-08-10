export class EbookLoadResources {
    #nativeSource
    #sourcePath
    #remoteBlob = null
    #closed = false

    constructor({ nativeSource = null, sourcePath = 'book.epub' } = {}) {
        this.#nativeSource = nativeSource
        this.#sourcePath = typeof sourcePath === 'string' && sourcePath.length > 0
            ? sourcePath
            : 'book.epub'
    }

    get diagnostics() {
        return {
            sourceKind: this.#nativeSource?.kind ?? (this.#remoteBlob ? 'file' : null),
            sourceURL: this.#nativeSource?.url ?? null,
            hasRemoteBlob: this.#remoteBlob != null,
        }
    }

    setRemoteBlob(blob) {
        if (this.#closed || this.#nativeSource || blob == null) return false
        this.#remoteBlob = blob
        return true
    }

    makeReusableSource({ makeFile, makeFileSource } = {}) {
        if (this.#closed) return null
        if (this.#nativeSource) return this.#nativeSource
        if (!this.#remoteBlob
            || typeof makeFile !== 'function'
            || typeof makeFileSource !== 'function') {
            return null
        }
        return makeFileSource(makeFile(this.#remoteBlob, this.#sourcePath))
    }

    close() {
        if (this.#closed) return false
        this.#closed = true
        this.#nativeSource = null
        this.#remoteBlob = null
        return true
    }
}
