// Immutable producer ownership is captured at the beginning of a native-bound
// operation. It is deliberately separate from live renderer state: a
// debounced callback, retry, or reply must never manufacture a new producer
// target from whatever happens to be visible when it runs.

/**
 * Capture the native-issued Article producer ticket installed by the Core
 * user script. `captureIfReady` also coalesces a cold setup handshake, but it
 * never queues or relabels the caller's event when setup is unavailable.
 */
export const captureReaderArticleProducerOwner = ({
    producer = globalThis.manabiArticleProducer,
} = {}) => {
    try {
        const owner = producer?.captureIfReady?.()
        if (!owner || typeof owner !== 'object') return null
        if (typeof owner.token !== 'string' || owner.token.length === 0) return null
        if (typeof owner.frameURL !== 'string' || owner.frameURL.length === 0) return null
        if (!Number.isFinite(owner.documentStartedAtMs)) return null
        return owner
    } catch (_error) {
        return null
    }
}

/**
 * Carry the original Core ticket into a fresh command object. If the real
 * producer bridge is present, its `own` method rejects forged/reused owners;
 * tests and non-bridge callers still receive the same immutable envelope.
 */
export const carryReaderArticleProducerOwner = (
    message,
    owner,
    { producer = globalThis.manabiArticleProducer } = {}
) => {
    if (!message || typeof message !== 'object' || !owner) return null
    try {
        if (typeof producer?.own === 'function') {
            return producer.own(message, owner)
        }
        Object.defineProperty(message, 'readerArticleProducer', {
            value: Object.freeze({
                token: owner.token,
                frameURL: owner.frameURL,
                documentStartedAtMs: owner.documentStartedAtMs,
            }),
            enumerable: true,
            writable: false,
            configurable: false,
        })
        return message
    } catch (_error) {
        return null
    }
}

export const readerArticleProducerOwnersMatch = (left, right) => {
    if (!left || !right) return false
    return left.token === right.token
        && left.frameURL === right.frameURL
        && left.documentStartedAtMs === right.documentStartedAtMs
}
