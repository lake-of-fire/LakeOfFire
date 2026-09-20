export const articleProducerLifetimeEventName =
    'manabi-article-producer-lifetime-changed'

const validToken = value =>
    typeof value === 'string'
    && value.length > 0
    && value.length <= 128

export const captureArticleProducerLifetime = (host = globalThis) => {
    const provider = host?.manabi_captureArticleProducerLifetimeToken
    if (typeof provider !== 'function') {
        return Object.freeze({ required: false, token: null })
    }
    let token = null
    try {
        token = provider.call(host)
    } catch (_error) {}
    return Object.freeze({
        required: true,
        token: validToken(token) ? token : null,
    })
}

export const withArticleProducerLifetime = (
    payload,
    evidence = captureArticleProducerLifetime()
) => {
    if (!payload || typeof payload !== 'object') return null
    if (evidence?.required === true && !validToken(evidence?.token)) {
        return null
    }
    if (!validToken(evidence?.token)) {
        return { ...payload }
    }
    return {
        ...payload,
        articleProducerLifetimeToken: evidence.token,
    }
}
