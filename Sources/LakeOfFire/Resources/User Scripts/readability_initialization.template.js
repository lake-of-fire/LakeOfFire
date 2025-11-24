(function () {
    const excludedDomains = new Set([
        "x.com",
        "twitter.com",
        "facebook.com",
        "instagram.com",
        "youtube.com",
        "web.whatsapp.com",
        "mail.google.com",
        "outlook.live.com",
        "discord.com",
        "teams.microsoft.com",
        "docs.google.com",
        "drive.google.com",
        "calendar.google.com",
        "slack.com",
        "notion.so",
        "linkedin.com",
        "reddit.com",
        "messenger.com",
        "meet.google.com",
        "tiktok.com",
        "amazon.com",
        "line.me",
        "mail.yahoo.co.jp",
    ]);
    
    ///////////////////
    // Utils
    ///////////////////
    
    function canHaveReadabilityContent() {
        if (window.top.location.protocol === "https:" && excludedDomains.has(window.top.location.host.toLowerCase())) {
            return false
        }
        if (window.top.location.protocol === "about:") {
            return false
        }
        return true
    }
    
    function readerLog(event, extra) {
        try {
            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
            if (!handler || typeof handler.postMessage !== "function") {
                return
            }
            const payload = {
                message: "# READER readabilityInit." + event,
                windowURL: getOriginURL(),
                pageURL: window.location.href,
            }
            if (extra && typeof extra === "object") {
                Object.keys(extra).forEach(key => {
                    const value = extra[key]
                    if (value !== undefined) {
                        payload[key] = value
                    }
                })
            }
            handler.postMessage(payload)
        } catch (error) {
            try {
                console.log("readabilityInit log error", error)
            } catch (_) {}
        }
    }
    
    function previewText(text, limit) {
        if (typeof text !== "string") {
            return null
        }
        const max = typeof limit === "number" ? limit : 512
        if (text.length <= max) {
            return text
        }
        return text.slice(0, max) + `...(truncated ${text.length - max} chars)`
    }

    function normalizeBylineText(rawByline) {
        if (typeof rawByline !== "string") {
            return ""
        }
        const trimmed = rawByline.trim()
        if (!trimmed) {
            return ""
        }
        const withoutPrefix = trimmed.replace(/^(by|par)\s+/i, "")
        return (withoutPrefix || trimmed).trim()
    }
    
    function captureBodyMetrics() {
        const body = document.body
        const readerContent = document.getElementById("reader-content")
        return {
            hasBody: !!body,
            bodyHTMLBytes: body && typeof body.innerHTML === "string" ? body.innerHTML.length : 0,
            bodyTextBytes: body && typeof body.textContent === "string" ? body.textContent.length : 0,
            hasReaderContent: !!readerContent,
            readerContentHTMLBytes: readerContent && typeof readerContent.innerHTML === "string" ? readerContent.innerHTML.length : 0,
            readerContentTextBytes: readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.length : 0,
        }
    }
    
    let lastBodyMetrics = null
    function maybeLogBodyMetrics(event, extra) {
        const current = captureBodyMetrics()
        const previous = lastBodyMetrics
        const previousBodyHTML = previous ? previous.bodyHTMLBytes : 0
        const previousReaderHTML = previous ? previous.readerContentHTMLBytes : 0
        if (current.hasBody && current.bodyHTMLBytes === 0 && (!previous || previousBodyHTML > 0)) {
            readerLog("emptyBodyDetected", {
                readyState: document.readyState || "unknown",
                bodyHTMLBytes: current.bodyHTMLBytes,
                bodyTextBytes: current.bodyTextBytes,
                outerHTMLBytes: document.documentElement?.outerHTML?.length || 0,
            })
        }
        const deltaBodyHTML = previous ? current.bodyHTMLBytes - previousBodyHTML : 0
        const deltaReaderHTML = previous ? current.readerContentHTMLBytes - previousReaderHTML : 0
        const shouldLog =
            !previous ||
            (current.bodyHTMLBytes === 0 && previousBodyHTML > 0) ||
            (previous && Math.abs(deltaBodyHTML) >= 512) ||
            (current.readerContentHTMLBytes === 0 && previousReaderHTML > 0) ||
            (previous && Math.abs(deltaReaderHTML) >= 256)
        if (!shouldLog) {
            return
        }
        lastBodyMetrics = current
        const payload = {
            ...current,
            deltaBodyHTMLBytes: previous ? deltaBodyHTML : null,
            deltaReaderContentHTMLBytes: previous ? deltaReaderHTML : null,
        }
        if (extra && typeof extra === "object") {
            Object.assign(payload, extra)
        }
        readerLog("bodyState." + event, payload)
    }
    
    function canonicalContentURL() {
        try {
            const href = window.location.href
            const url = new URL(href)
            if (url.protocol === "internal:" && url.host === "local" && url.pathname === "/load/reader") {
                const readerURL = new URLSearchParams(url.search || "").get("reader-url")
                if (readerURL) {
                    return decodeURIComponent(readerURL)
                }
            }
            return href
        } catch (_) {
            return window.location.href
        }
    }

    function getOriginURL() {
        // Always use the canonical article URL so frame registration lines up with Swift lookups.
        return canonicalContentURL()
    }
    
    function nextManabiUniqueIdentifier() {
        let body = window.top.document.body
        let next = (body?.dataset.manabiLatestUniqueIdentifierCounter || 1) + 1
        body.dataset.manabiLatestUniqueIdentifierCounter = next
        return next.toString(10)
    }
    
    function closestFrameSelector() {
        if (window.frameElement === null) { return null }
        if (!('readabilityUniqueIdentifier' in window.frameElement.dataset)) {
            window.frameElement.dataset.readabilityUniqueIdentifier = nextManabiUniqueIdentifier()
        }
        return {
        selector: '[data-readabilityUniqueIdentifier="' + window.frameElement.dataset.readabilityUniqueIdentifier + '"]',
        node: window.frameElement,
        }
    }
    
    function closestShadowRootSelector(fromNode) {
        let rootNode = fromNode.getRootNode()
        if (rootNode && rootNode.host && rootNode.host.shadowRoot) {
            let host = rootNode.host
            if (!('readabilityUniqueIdentifier' in host.dataset)) {
                host.dataset.readabilityUniqueIdentifier = nextManabiUniqueIdentifier()
            }
            return {
            selector: '[data-readabilityUniqueIdentifier="' + host.dataset.readabilityUniqueIdentifier + '"]',
            node: host,
            }
        }
        return null
    }
    
    // Returns a function, that, as long as it continues to be invoked, will not
    // be triggered. The function will be called after it stops being called for
    // N milliseconds. If `immediate` is passed, trigger the function on the
    // leading edge, instead of the trailing.
    // https://davidwalsh.name/javascript-debounce-function
    let manabi_debounce = function (func, wait, immediate) {
        var timeout
        
        return function executedFunction() {
            var context = this
            var args = arguments
            
            let later = function () {
                timeout = null
                if (!immediate) {
                    func.apply(context, args)
                }
            }
            
            var callNow = immediate && !timeout
            clearTimeout(timeout)
            timeout = setTimeout(later, wait)
            if (callNow) {
                func.apply(context, args)
            }
        }
    }
    
    function isInternalURL(url) {
        return /^internal:\/\/local\//.test(url);
    }
    
    let manabi_readability = function () {
        const body = document.body
        const nextLoadFlag = body?.dataset?.isNextLoadInReaderMode === 'true' || body?.dataset?.nextLoadIsReadabilityMode === 'true'
        const hasReadabilityMode = body?.classList.contains('readability-mode')
        const hasReaderContent = document.getElementById('reader-content') !== null
        const shouldProcess = (window.top.location.protocol !== 'ebook:' && nextLoadFlag) || (!hasReadabilityMode && !hasReaderContent)

        // Don't run on already-Readability-ified content unless explicitly requested for the next load.
        if (shouldProcess) {
            // Only process document if it didn't already come from SwiftReadability's output.
            // Ensures idempotency.
            
            var loc = document.location;
            var uri = {
                spec: loc.href,
                host: loc.host,
                prePath: loc.protocol + "//" + loc.host,
                scheme: loc.protocol.substr(0, loc.protocol.indexOf(":")),
                pathBase: loc.protocol + "//" + loc.host + loc.pathname.substr(0, loc.pathname.lastIndexOf("/") + 1)
            };
            let windowURL = getOriginURL()
            
            if (window.location.protocol === "blob:" || window.location.origin.startsWith('ebook://')) {
                // Don't run this script on eBooks, leave that to the swift processing callback
                return
            } else {
                if (!canHaveReadabilityContent()) {
                    window.webkit.messageHandlers.readabilityModeUnavailable.postMessage({
                        pageURL: loc.href,
                        windowURL: windowURL,
                    })
                    return
                }
                
                maybeLogBodyMetrics("beforeClone", { context: "manabi_readability" })
                const liveBody = document.body
                readerLog("bootstrapBodyContent", {
                    readyState: document.readyState || "unknown",
                    hasBody: !!liveBody,
                    bodyHTMLBytes: liveBody && typeof liveBody.innerHTML === "string" ? liveBody.innerHTML.length : 0,
                    bodyTextBytes: liveBody && typeof liveBody.textContent === "string" ? liveBody.textContent.length : 0,
                    bodyPreview: previewText(liveBody && typeof liveBody.innerHTML === "string" ? liveBody.innerHTML : null, 512),
                })
                var documentClone = document.cloneNode(true);
                let inputHTML = documentClone.documentElement.outerHTML
                const bodyElement = documentClone.body
                const bodyTextLength = bodyElement && typeof bodyElement.textContent === "string" ? bodyElement.textContent.length : 0
                const bodyHTMLLength = bodyElement && typeof bodyElement.innerHTML === "string" ? bodyElement.innerHTML.length : 0
                const readerContentElement = documentClone.getElementById("reader-content")
                const readerContentLength = readerContentElement && typeof readerContentElement.textContent === "string" ? readerContentElement.textContent.length : 0
                readerLog("inputCaptured", {
                    readyState: document.readyState || "unknown",
                    hasBody: !!document.body,
                    bodyHTMLBytes: bodyHTMLLength,
                    bodyTextBytes: bodyTextLength,
                    hasReaderContent: !!readerContentElement,
                    readerContentBytes: readerContentLength,
                    inputBytes: inputHTML ? inputHTML.length : 0,
                    inputPreview: previewText(inputHTML, 1024),
                })
                var article = new Readability(uri, documentClone, {
                    // https://github.com/mozilla/gecko-dev/blob/246928d59c6c11e1c3b3b0a6b00534bfc075e3c4/toolkit/components/reader/ReaderMode.jsm#L21-L31
                classesToPreserve: [
                    "caption", "emoji", "hidden", "invisible", "sr-only", "visually-hidden", "visuallyhidden", "wp-caption", "wp-caption-text", "wp-smiley"
                ],
                    charThreshold: ##CHAR_THRESHOLD##}).parse();
                readerLog("articleContent", {
                    hasArticle: !!article,
                    bodyHTMLBytes: bodyHTMLLength,
                    bodyTextBytes: bodyTextLength,
                    readerContentBytes: readerContentLength,
                    hasReaderContent: !!readerContentElement,
                    titleBytes: article && typeof article.title === "string" ? article.title.length : 0,
                    bylineBytes: article && typeof article.byline === "string" ? article.byline.length : 0,
                    contentBytes: article && typeof article.content === "string" ? article.content.length : 0,
                    hasMarkup: !!(article && typeof article.content === "string" && article.content.indexOf("<body") !== -1),
                    contentPreview: previewText(article && typeof article.content === "string" ? article.content : null, 512),
                })
                
                const rawTitle = article && typeof article.title === "string" ? article.title : ""
                const rawByline = article && typeof article.byline === "string" ? article.byline : ""
                const rawContent = article && typeof article.content === "string" ? article.content : ""
                const publishedTime = article && typeof article.publishedTime === "string" ? article.publishedTime : null
                readerLog("rawContent", {
                    titleBytes: rawTitle.length,
                    bylineBytes: rawByline.length,
                    contentBytes: rawContent.length,
                    preview: previewText(rawContent, 512),
                })
                
                if (article === null) {
                    readerLog("articleParseFailed", {
                        readyState: document.readyState || "unknown",
                        bodyHTMLBytes: bodyHTMLLength,
                        bodyTextBytes: bodyTextLength,
                        readerContentBytes: readerContentLength,
                        hasReaderContent: !!readerContentElement,
                        inputBytes: inputHTML ? inputHTML.length : 0,
                    })
                    if (document.body) {
                        document.body.dataset.manabiReaderModeAvailable = 'false';
                        document.body.dataset.isNextLoadInReaderMode = 'false';
                        document.body.dataset.nextLoadIsReadabilityMode = 'false';
                        delete document.body.dataset.manabiReaderModeAvailableFor;
                    }
                    window.webkit.messageHandlers.readabilityModeUnavailable.postMessage({
                        pageURL: loc.href,
                        windowURL: windowURL,
                    })
                } else {
                    let contentIsInternal = isInternalURL(uri.spec)
                    let title = DOMPurify.sanitize(rawTitle)
                    let byline = DOMPurify.sanitize(rawByline)
                    const displayByline = normalizeBylineText(byline)
                    const hasByline = displayByline.length > 0
                    var content = DOMPurify.sanitize(rawContent)
                    const sanitizedContentBytes = content && typeof content === "string" ? content.length : 0
                    const hasReaderBody = typeof content === "string" && content.indexOf('id="reader-content"') !== -1
                    readerLog("sanitizedContent", {
                        contentBytes: sanitizedContentBytes,
                        hasReaderBody: hasReaderBody,
                        hasMarkup: !!(content && typeof content === "string" && content.indexOf("<body") !== -1),
                        preview: previewText(content, 512),
                    })
                    let viewOriginal = contentIsInternal ? '' : `<a class="reader-view-original">View Original</a>`

                    const bylineLine = hasByline
                        ? `<div id="reader-byline-line" class="byline-line"><span class="byline-label">By</span> <span id="reader-byline" class="byline">${displayByline}</span></div>`
                        : ''
                    const metaLine = `<div id="reader-meta-line" class="byline-meta-line"><span id="reader-publication-date"></span>${viewOriginal ? `<span class="reader-meta-divider"></span>${viewOriginal}` : ''}</div>`
                    
                    /*
                     let openGraphImage = document.head.querySelector('meta[property="og:image"]')
                     if (openGraphImage) {
                     let url = openGraphImage.getAttribute('content')
                     if (url) {
                     let path = new URL(url).pathname
                     if (path && !content.includes(path)) {
                     content = DOMPurify.sanitize(`<img src='${url}'>`) + content
                     }
                     }
                     }
                     */
                    
                    // IMPORTANT: Keep `<body class="readability-mode">` text fragment, or update Reader.swift's check for it.
                    
                    // Forked off https://github.com/mozilla/firefox-ios/blob/5238e873e77e9ad3e699f926d12f61ccafabdc11/Client/Frontend/Reader/Reader.html
                    // IMPORTANT: Match this template to ReaderContentProtocol.htmlToDisplay
                    let html = `
<!DOCTYPE html>
<html>
    <head>
        <meta content="text/html; charset=UTF-8" http-equiv="content-type">
        <meta name="viewport" content="width=device-width, user-scalable=no, minimum-scale=1.0, maximum-scale=1.0, initial-scale=1.0">
        <meta name="referrer" content="never">
        <style id='swiftuiwebview-readability-styles'>
            ##CSS##
        </style>
        <title>${title}</title>
    </head>

    <body class="readability-mode">
        <div id="reader-header" class="header">
            <h1 id="reader-title">${title}</h1>
            <div id="reader-byline-container">
                ${bylineLine}
                ${metaLine}
            </div>
        </div>
        <div id="reader-content">
            ${content}
        </div>
        <script>
            ##SCRIPT##
        </script>
        <script>
            (function () {
                function logDocumentState(reason) {
                    try {
                        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
                        if (!handler || typeof handler.postMessage !== "function") {
                            return
                        }
                        const readerContent = document.getElementById("reader-content")
                        const payload = {
                            message: "# READER snippetLoader.documentReady",
                            reason: reason,
                            bodyHTMLBytes: document.body && typeof document.body.innerHTML === "string" ? document.body.innerHTML.length : 0,
                            bodyTextBytes: document.body && typeof document.body.textContent === "string" ? document.body.textContent.length : 0,
                            hasReaderContent: !!readerContent,
                            readerContentHTMLBytes: readerContent && typeof readerContent.innerHTML === "string" ? readerContent.innerHTML.length : 0,
                            readerContentTextBytes: readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.length : 0,
                            readerContentPreview: readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.slice(0, 240) : null,
                            windowURL: window.location.href,
                            pageURL: document.location.href
                        }
                        handler.postMessage(payload)
                    } catch (error) {
                        try {
                            console.log("snippetLoader.documentReady log error", error)
                        } catch (_) {}
                    }
                }
                if (document.readyState === "complete" || document.readyState === "interactive") {
                    logDocumentState("immediate")
                } else {
                    document.addEventListener("DOMContentLoaded", function () {
                        logDocumentState("domcontentloaded")
                    }, { once: true })
                }
            })();
        </script>
    </body>
</html>
`
                    const htmlBytes = typeof html === "string" ? html.length : 0
                    const hasReaderBody = typeof html === "string" ? html.indexOf('id="reader-content"') !== -1 : false
                    readerLog("htmlTemplatePrepared", {
                        outputBytes: htmlBytes,
                        contentBytes: sanitizedContentBytes,
                        hasReaderBody: hasReaderBody,
                        readerContentPreview: previewText(content, 512),
                    })
                    if (!hasReaderBody) {
                        readerLog("missingReaderContent", {
                            reason: "htmlTemplatePrepared",
                            contentBytes: sanitizedContentBytes,
                            outputBytes: htmlBytes,
                        })
                    }

                    // 0 is innermost.
                    // Currently only supports optional [shadowRoot][shadowRoot][iframe] nesting
                    /*
                     let layer0FrameSelector = closestFrameSelector()
                     let layer1ShadowRootSelector = getShadowRootSelector(layer0FrameSelector ? layer0FrameSelector.node : document)
                     let layer2ShadowRootSelector = layer1ShadowRootSelector ? closestShadowRootSelector(layer1 layer1ShadowRootSelector.node) : null
                     */

                    if (document.body) {
                        if (content) {
                            document.body.dataset.manabiReaderModeAvailable = 'true';
                        document.body.dataset.manabiReaderModeAvailableFor = windowURL;
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                            document.body.dataset.nextLoadIsReadabilityMode = 'false';
                            const hasReaderBody = html.indexOf('id="reader-content"') !== -1
                            readerLog("outputPrepared", {
                                contentBytes: content.length,
                                outputBytes: html.length,
                                hasReaderBody: hasReaderBody,
                                contentPreview: previewText(content, 512),
                            })
                            if (!hasReaderBody) {
                                readerLog("missingReaderContent", {
                                    reason: "outputPrepared",
                                    contentBytes: content.length,
                                    outputBytes: html.length,
                                })
                            }
                            readerLog("readabilityParsedPayload", {
                                contentBytes: content.length,
                                outputBytes: html.length,
                                windowURL: windowURL,
                                pageURL: loc.href,
                            })
                            
                            window.webkit.messageHandlers.readabilityParsed.postMessage({
                                pageURL: loc.href,
                                windowURL: windowURL,
                                readabilityContainerSelector: null,
                                title: title,
                                byline: byline,
                                publishedTime: publishedTime,
                                content: content,
                                inputHTML: inputHTML,
                                outputHTML: html,
                            })
                        } else {
                            document.body.dataset.manabiReaderModeAvailable = 'false';
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                            document.body.dataset.nextLoadIsReadabilityMode = 'false';
                            delete document.body.dataset.manabiReaderModeAvailableFor;

                            window.webkit.messageHandlers.readabilityModeUnavailable.postMessage({
                                pageURL: loc.href,
                                windowURL: windowURL,
                            })
                        }
                    } else {
                        window.webkit.messageHandlers.readabilityModeUnavailable.postMessage({
                            pageURL: loc.href,
                            windowURL: windowURL,
                        })
                    }
                }
            }
        }
    }

    let manabi_debouncedReadability = manabi_debounce(function () {
        if (document.body.dataset.manabiReaderModeAvailableFor !== window.location.href) {
            manabi_readability()
        }
    } , 3 * 1000)
    
    let initialize = function () {
        if (window.location.protocol === 'about:') {
            return
        }
        
        var observer = new MutationObserver(function (mutations) {
            mutations.forEach(function(mutation) {
                if (mutation.type === 'attributes' && mutation.attributeName === 'class') {
                    for (cls of mutation.target.classList) {
                        if (cls.startsWith('manabi-')) {
                            return
                        }
                    }
                }
                if (mutation.type === 'attributes' && mutation.attributeName.startsWith('data-manabi-')) {
                    return
                }
                try {
                    const body = document.body
                    const readerContent = document.getElementById("reader-content")
                    readerLog("mutationSummary", {
                        mutationType: mutation.type,
                        attributeName: mutation.attributeName || null,
                        targetTag: mutation.target && mutation.target.tagName ? mutation.target.tagName : null,
                        addedNodes: mutation.addedNodes ? mutation.addedNodes.length : 0,
                        removedNodes: mutation.removedNodes ? mutation.removedNodes.length : 0,
                        bodyHTMLBytes: body && typeof body.innerHTML === "string" ? body.innerHTML.length : 0,
                        readerContentHTMLBytes: readerContent && typeof readerContent.innerHTML === "string" ? readerContent.innerHTML.length : 0,
                    })
                } catch (error) {
                    try { console.log("mutationSummary log error", error) } catch (_) {}
                }
                maybeLogBodyMetrics("mutation", {
                    mutationType: mutation.type,
                    attributeName: mutation.attributeName || null,
                    targetTag: mutation.target && mutation.target.tagName ? mutation.target.tagName : null,
                    addedNodes: mutation.addedNodes ? mutation.addedNodes.length : 0,
                    removedNodes: mutation.removedNodes ? mutation.removedNodes.length : 0,
                })
                if ((mutation.target.textContent?.length || 0) > 1) {
                    manabi_debouncedReadability()
                }
            })
        })
        let observerConfig = {attributes: true, childList: true,  characterData: true}
        
        let attachShadow = Element.prototype.attachShadow
        Element.prototype.attachShadow = function (shadowConfig) {
            let shadow = attachShadow.call(this, {...shadowConfig, mode: 'open'})
            observer.observe(shadow, observerConfig)
            return shadow
        }
        
        let uuid = null;
        let initializeFrameStateRefreshes = () => {
            //if (document.body) {
                //let uuid = document.body?.dataset.swiftuiwebviewFrameUuid
                if (!uuid) {
                    if (crypto && crypto.randomUUID) {
                        uuid = crypto.randomUUID()
                    } else {
                        uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                            var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
                            return v.toString(16);
                        })
                    }
                    //document.body.dataset.swiftuiwebviewFrameUuid = uuid
                }
            //}

            let windowURL = getOriginURL()
            //let uuid = document.body?.dataset.swiftuiwebviewFrameUuid

            if (document.body?.classList.contains('readability-mode') && (window.frameElement !== null || window !== window.parent)) {
                setInterval(() => {
                    window.webkit.messageHandlers.readabilityFramePing.postMessage({
                        uuid: uuid,
                        windowURL: windowURL,
                    })
                }, 10 * 1000)
                
                window.webkit.messageHandlers.readabilityFramePing.postMessage({
                    uuid: uuid,
                    windowURL: windowURL,
                })
            }
        };
        
        let hasCalledReadabilityOnPageLoad = false;
        if (document.readyState === 'complete') {
            if (!hasCalledReadabilityOnPageLoad) {
                hasCalledReadabilityOnPageLoad = true
                manabi_readability()
                initializeFrameStateRefreshes()
                observer.observe(document, observerConfig)
            }
        } else {
            document.addEventListener('DOMContentLoaded', (event) => {
                if (!hasCalledReadabilityOnPageLoad) {
                    hasCalledReadabilityOnPageLoad = true
                    manabi_readability()
                    initializeFrameStateRefreshes()
                    observer.observe(document, observerConfig)
                }
            })
            document.addEventListener('readystatechange', () => {
                if (document.readyState === 'complete' && !hasCalledReadabilityOnPageLoad) {
                    hasCalledReadabilityOnPageLoad = true
                    manabi_readability()
                    initializeFrameStateRefreshes()
                    observer.observe(document, observerConfig)
                }
            })
        }
        
        let oldOnShow = window.onpageshow
        window.onpageshow = function(event) {
            if (event.persisted) {
                // From back/forward cache... Re-run initialization
                manabi_readability()
                initializeFrameStateRefreshes()
                observer.observe(document, observerConfig)
            }
            if (oldOnShow) {
                oldOnShow(event)
            }
        }
    }
    
    initialize()
    //     if (document.readyState === 'complete') {
    //         initialize()
    //     } else {
    //         document.addEventListener('DOMContentLoaded', initialize)
    //     }
})();
