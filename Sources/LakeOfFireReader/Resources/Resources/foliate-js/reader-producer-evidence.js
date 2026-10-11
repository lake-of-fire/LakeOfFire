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
    // LakeOfFireReader also runs in hosts that do not install Manabi's native
    // producer contract. Preserve their historical local message path. Once a
    // host exposes the producer object, however, an unavailable/malformed
    // capture must fail closed rather than becoming an unfenced message.
    if (producer == null) {
        return Object.freeze({ required: false })
    }
    if (typeof producer.captureIfReady !== 'function') return null
    try {
        const owner = producer.captureIfReady()
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
    if (owner.required === false) return message
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

// Availability is observational: unlike event capture it must not start setup.
export const readerArticleProducerOwnerIsCurrent = (owner, {
    producer = globalThis.manabiArticleProducer,
} = {}) => {
    if (!owner) return false
    if (owner.required === false) return producer == null
    if (typeof owner.token !== 'string' || !owner.token
        || typeof owner.frameURL !== 'string' || !owner.frameURL
        || !Number.isFinite(owner.documentStartedAtMs)) return false
    try { return producer?.isCurrent?.(owner) === true }
    catch (_) { return false }
}

export const observeReaderArticleProducerReadiness = ({
    target = globalThis,
    getProducer = () => globalThis.manabiArticleProducer,
    isCurrent = () => true,
    onChange = () => {},
} = {}) => {
    let closed = false, installation = null, generation = 0
    const live = () => !closed && isCurrent()
    const release = value => {
        try { value?.unsubscribe?.() } catch (_) {}
    }
    const ready = () => {
        if (!live() || !installation) return false
        const selected = installation
        const producer = getProducer()
        return installation === selected && live() && producer === selected.producer
            && readerArticleProducerOwnerIsCurrent(selected.owner, { producer })
            && installation === selected && live()
    }
    const refresh = () => {
        if (!live()) return
        const ticket = ++generation, previous = installation
        installation = null
        release(previous)
        if (!live() || generation !== ticket) return
        const producer = getProducer()
        let owner = null
        try {
            owner = producer == null ? Object.freeze({ required: false }) : producer.capture?.()
            if (!readerArticleProducerOwnerIsCurrent(owner, { producer })) owner = null
        } catch (_) {}
        const currentProducer = getProducer()
        if (!live() || generation !== ticket || currentProducer !== producer) return
        if (!owner) { onChange(false); return }
        const selected = installation = { producer, owner, unsubscribe: null }
        if (producer != null) {
            try {
                const unsubscribe = producer.onInvalidated(owner, () => {
                    if (!live() || installation !== selected) return
                    // Retire before callbacks; a nested ready event owns its successor.
                    ++generation
                    installation = null
                    release(selected)
                    if (live() && installation === null) onChange(false)
                })
                if (installation !== selected || !live()) {
                    release({ unsubscribe })
                    return
                }
                selected.unsubscribe = unsubscribe
            } catch (_) {
                if (installation !== selected) return
                installation = null
                if (live()) onChange(false)
                return
            }
        }
        const available = ready()
        if (installation === selected && live() && generation === ticket) onChange(available)
    }
    target.addEventListener?.('manabi-article-producer-ready', refresh)
    refresh()
    return {
        get ready() { return ready() },
        close() {
            if (closed) return
            closed = true
            ++generation
            const previous = installation
            installation = null
            target.removeEventListener?.('manabi-article-producer-ready', refresh)
            release(previous)
        },
    }
}
