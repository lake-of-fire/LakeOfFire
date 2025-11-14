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
    
    function getOriginURL() {
        return window.top.location.href;
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
        // Don't run on already-Readability-ified content
        if (window.top.location.protocol !== 'ebook:' && document.body?.dataset.isNextLoadInReaderMode === 'true' || (!document.body?.classList.contains('readability-mode') && document.getElementById('reader-content') === null)) {
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
                var documentClone = document.cloneNode(true);
                let inputHTML = documentClone.documentElement.outerHTML
                const bodyElement = documentClone.body
                const bodyTextLength = bodyElement && typeof bodyElement.textContent === "string" ? bodyElement.textContent.length : 0
                const bodyHTMLLength = bodyElement && typeof bodyElement.innerHTML === "string" ? bodyElement.innerHTML.length : 0
                const readerContentElement = documentClone.getElementById("reader-content")
                const readerContentLength = readerContentElement && typeof readerContentElement.textContent === "string" ? readerContentElement.textContent.length : 0
                var article = new Readability(uri, documentClone, {
                    // https://github.com/mozilla/gecko-dev/blob/246928d59c6c11e1c3b3b0a6b00534bfc075e3c4/toolkit/components/reader/ReaderMode.jsm#L21-L31
                classesToPreserve: [
                    "caption", "emoji", "hidden", "invisible", "sr-only", "visually-hidden", "visuallyhidden", "wp-caption", "wp-caption-text", "wp-smiley"
                ],
                    charThreshold: ##CHAR_THRESHOLD##}).parse();
                const rawTitle = article && typeof article.title === "string" ? article.title : ""
                const rawByline = article && typeof article.byline === "string" ? article.byline : ""
                const rawContent = article && typeof article.content === "string" ? article.content : ""
                
                if (article === null) {
                    if (document.body) {
                        document.body.dataset.manabiReaderModeAvailable = 'false';
                        document.body.dataset.isNextLoadInReaderMode = 'false';
                    }
                    window.webkit.messageHandlers.readabilityModeUnavailable.postMessage({
                        pageURL: loc.href,
                        windowURL: windowURL,
                    })
                } else {
                    let contentIsInternal = isInternalURL(uri.spec)
                    let title = DOMPurify.sanitize(rawTitle)
                    let byline = DOMPurify.sanitize(rawByline)
                    var content = DOMPurify.sanitize(rawContent)
                    const sanitizedContentBytes = content && typeof content === "string" ? content.length : 0
                    let viewOriginal = contentIsInternal ? '' : `<a class="reader-view-original">View Original</a>`
                    
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
                <span id="reader-byline" class="byline">${byline}</span>
                ${viewOriginal}
            </div>
        </div>
        <div id="reader-content">
            ${content}
        </div>
        <script>
            ##SCRIPT##
        </script>
    </body>
</html>
`
                    const htmlBytes = typeof html === "string" ? html.length : 0

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
                            document.body.dataset.manabiReaderModeAvailableFor = loc.href;
                            
                            window.webkit.messageHandlers.readabilityParsed.postMessage({
                                pageURL: loc.href,
                                windowURL: windowURL,
                                readabilityContainerSelector: null,
                                title: title,
                                byline: byline,
                                content: content,
                                inputHTML: inputHTML,
                                outputHTML: html,
                            })
                        } else {
                            document.body.dataset.manabiReaderModeAvailable = 'false';
                            document.body.dataset.isNextLoadInReaderMode = 'false';
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
