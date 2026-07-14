export const BOOK_CONTENT_STYLE_ID = 'foliate-book-content-style'

export const installBookContentStyles = (installationByDocument, doc, stylesPromise) => {
    if (!doc?.head || !stylesPromise) return Promise.resolve(false)
    const existingInstallation = installationByDocument.get(doc)
    if (existingInstallation?.stylesPromise === stylesPromise) {
        return existingInstallation.promise
    }

    const installation = { stylesPromise, promise: null }
    const promise = Promise.resolve(stylesPromise).then(styles => {
        if (installationByDocument.get(doc) !== installation) return false
        let style = doc.getElementById(BOOK_CONTENT_STYLE_ID)
        if (style && style.localName !== 'style') {
            style.remove()
            style = null
        }
        if (!style) {
            style = doc.createElement('style')
            style.id = BOOK_CONTENT_STYLE_ID
            doc.head.prepend(style)
        }
        if (style.textContent !== styles) style.textContent = styles
        return true
    })
    installation.promise = promise
    installationByDocument.set(doc, installation)
    return promise
}
