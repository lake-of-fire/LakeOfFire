// Core and Lake share a finite, immutable stamp on the actual Document.
// A Window/WindowProxy can survive replacement; it is not the cache key.
const documentsWithoutOrigin = new WeakSet()

export function readerDocumentStartedAtMs(view = globalThis) {
    const doc = view?.document
    if (!doc) return null
    const stamp = Object.getOwnPropertyDescriptor(doc, 'manabiDocumentStartedAtMs')
    if (stamp) {
        if (!Number.isFinite(stamp.value) || stamp.writable || stamp.configurable) {
            throw new TypeError('Invalid canonical reader document clock')
        }
        return stamp.value
    }
    if (documentsWithoutOrigin.has(doc)) return null
    const sampledOrigin = view.performance?.timeOrigin
    if (!Number.isFinite(sampledOrigin)) {
        // Standalone Lake historically emits null without an engine origin.
        // Core can still establish its Date.now() fallback later; absence is
        // not a competing identity, and the canonical stamp is checked first.
        documentsWithoutOrigin.add(doc)
        return null
    }
    Object.defineProperty(doc, 'manabiDocumentStartedAtMs', { value: sampledOrigin })
    return sampledOrigin
}
