export const articleMutationProducerEventName =
    'manabi-article-mutation-producer-changed'

const validToken = value =>
    typeof value === 'string'
    && value.length > 0
    && value.length <= 128

export const captureArticleMutationProducer = (host = globalThis) => {
    const provider = host?.manabi_captureArticleMutationProducerToken
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

export const withArticleMutationProducer = (
    payload,
    evidence = captureArticleMutationProducer()
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
        articleMutationProducerToken: evidence.token,
    }
}
