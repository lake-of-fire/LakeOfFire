// A transient DOM handoff between the producer and page content worlds.
// The token permits one prepared render effect; it grants no native authority.
(() => {
    const attribute = 'data-reader-frame-replacement-token'
    const validToken = token => typeof token === 'string' && token.length > 0
    const clearMatching = token => {
        const root = document.documentElement
        if (!validToken(token) || !root || root.getAttribute(attribute) !== token) return false
        root.removeAttribute(attribute)
        return true
    }
    return Object.freeze({
        capture(token) {
            const root = document.documentElement
            if (!validToken(token) || !root) return false
            root.setAttribute(attribute, token)
            return root.getAttribute(attribute) === token
        },
        consume: clearMatching,
        discard: clearMatching,
    })
})()
