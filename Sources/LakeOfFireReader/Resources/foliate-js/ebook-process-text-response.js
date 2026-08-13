export const ebookProcessTextResponseIsAuthoritative = response => (
    response?.headers?.get?.('x-manabi-processing-authoritative') === 'true'
)
