const XML_NAMESPACE = 'http://www.w3.org/XML/1998/namespace'

// XML language wins on one element. HTML serialization can retain the
// qualified spelling without its namespace, so preserve that spelling too.
// An explicit empty language means unknown, rather than inherited language.
const elementLanguage = element => element?.getAttributeNS?.(XML_NAMESPACE, 'lang')
    ?? element?.getAttribute?.('xml:lang')
    ?? element?.getAttribute?.('lang')
    ?? (element?.lang || undefined)

export const getDocumentLanguage = doc => elementLanguage(doc?.body)
    ?? elementLanguage(doc?.documentElement)
