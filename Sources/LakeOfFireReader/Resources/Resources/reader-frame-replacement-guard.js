// A transient DOM handoff between the producer and page content worlds.
// The token permits one prepared render effect; it grants no native authority.
(() => {
    const attribute = 'data-reader-frame-replacement-token'
    const supersedeEvent = 'reader-frame-replacement-supersede'
    const requestEvent = token => `reader-frame-replacement-request:${token}`
    const validToken = token => typeof token === 'string' && token.length > 0
    const clearMatching = token => {
        const capturedDocument = document
        const root = capturedDocument.documentElement
        if (!validToken(token) || !root || root.getAttribute(attribute) !== token) return false
        // A copied attribute cannot acknowledge: DOM cloning/importing does
        // not copy the listener installed on the captured physical root.
        const acknowledged = !root.dispatchEvent(new Event(requestEvent(token), { cancelable: true }))
        return acknowledged && document === capturedDocument && document.documentElement === root
            && root.getAttribute(attribute) === null
    }
    return Object.freeze({
        capture(token) {
            const root = document.documentElement
            if (!validToken(token) || !root) return false
            const capturedDocument = document
            root.dispatchEvent(new Event(supersedeEvent))
            if (document !== capturedDocument || document.documentElement !== root) return false
            const requestType = requestEvent(token)
            const exactRootEvent = event => document === capturedDocument
                && document.documentElement === root
                && event.target === root && event.currentTarget === root
            const cleanup = () => {
                root.removeEventListener(requestType, acknowledge)
                root.removeEventListener(supersedeEvent, supersede)
            }
            const acknowledge = event => {
                if (!exactRootEvent(event) || !event.cancelable || root.getAttribute(attribute) !== token) return
                cleanup()
                root.removeAttribute(attribute)
                event.preventDefault()
            }
            const supersede = event => {
                if (exactRootEvent(event)) cleanup()
            }
            root.addEventListener(requestType, acknowledge)
            root.addEventListener(supersedeEvent, supersede)
            root.setAttribute(attribute, token)
            if (root.getAttribute(attribute) === token) return true
            cleanup()
            return false
        },
        consume: clearMatching,
        discard: clearMatching,
    })
})()
