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
    
    function getOriginURL() {
        return window.top.location.href;
    }
    
    function nextManabiUniqueIdentifier() {
        let body = window.top.document.body
        let next = (body?.dataset.mnbLatestUniqueIdentifierCounter || 1) + 1
        body.dataset.mnbLatestUniqueIdentifierCounter = next
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

    const wikimediaHostSuffixes = [
        "mediawiki.org",
        "wikibooks.org",
        "wikidata.org",
        "wikifunctions.org",
        "wikimedia.org",
        "wikinews.org",
        "wikipedia.org",
        "wikiquote.org",
        "wikisource.org",
        "wikiversity.org",
        "wikivoyage.org",
        "wiktionary.org",
    ];

    function hostMatchesSuffix(host, suffix) {
        return host === suffix || host.endsWith("." + suffix);
    }

    function readabilityDocumentHost(uri, doc) {
        const uriHost = (uri && typeof uri.host === "string") ? uri.host.trim().toLowerCase() : "";
        if (uriHost) {
            return uriHost;
        }

        const baseURI = (doc && typeof doc.baseURI === "string") ? doc.baseURI : "";
        if (!baseURI) {
            return "";
        }

        try {
            return new URL(baseURI).host.trim().toLowerCase();
        } catch (_) {
            return "";
        }
    }

    function isWikimediaMinervaCollapsiblePage(uri, doc) {
        if (!doc || typeof doc.querySelector !== "function") {
            return false;
        }

        const host = readabilityDocumentHost(uri, doc);
        if (!host || !wikimediaHostSuffixes.some((suffix) => hostMatchesSuffix(host, suffix))) {
            return false;
        }

        return doc.querySelector("div.section-heading + section.collapsible-block") !== null;
    }

    // Temporary Wikimedia Minerva workaround: move collapsible section headings into
    // the adjacent section body so Readability evaluates heading and body together.
    function normalizeWikimediaMinervaCollapsibleSections(doc) {
        if (!doc || typeof doc.querySelectorAll !== "function") {
            return;
        }

        const sectionBlocks = doc.querySelectorAll("div.section-heading + section.collapsible-block");
        for (const section of sectionBlocks) {
            const headingWrapper = section.previousElementSibling;
            if (!headingWrapper || !headingWrapper.matches("div.section-heading")) {
                continue;
            }

            const sourceHeading = headingWrapper.querySelector("h1, h2, h3, h4, h5, h6");
            const headingText = (sourceHeading && sourceHeading.textContent ? sourceHeading.textContent.trim() : "");
            if (!sourceHeading || !headingText) {
                continue;
            }

            const normalizedHeading = doc.createElement(sourceHeading.tagName.toLowerCase());
            normalizedHeading.textContent = headingText;

            const id = sourceHeading.getAttribute("id");
            if (id) {
                normalizedHeading.setAttribute("id", id);
            }

            const lang = sourceHeading.getAttribute("lang") || headingWrapper.getAttribute("lang");
            if (lang) {
                normalizedHeading.setAttribute("lang", lang);
            }

            const dir = sourceHeading.getAttribute("dir") || headingWrapper.getAttribute("dir");
            if (dir) {
                normalizedHeading.setAttribute("dir", dir);
            }

            section.prepend(normalizedHeading);
            headingWrapper.remove();
        }
    }

    function normalizeRubyForReadability(doc) {
        if (!doc || typeof doc.querySelectorAll !== "function") {
            return;
        }
        for (const rp of doc.querySelectorAll("ruby rp")) {
            rp.remove();
        }
        for (const rb of doc.querySelectorAll("ruby rb")) {
            rb.replaceWith(...Array.from(rb.childNodes));
        }
    }

    function formatReadabilityPublishedTime(rawValue) {
        if (!rawValue) {
            return '';
        }
        let date = new Date(rawValue);
        if (Number.isNaN(date.getTime())) {
            return rawValue;
        }
        try {
            return new Intl.DateTimeFormat(undefined, { dateStyle: 'short' }).format(date);
        } catch (_error) {
            return date.toLocaleDateString();
        }
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
                var parserInputClone = documentClone.cloneNode(true);
                normalizeRubyForReadability(parserInputClone);
                if (isWikimediaMinervaCollapsiblePage(uri, parserInputClone)) {
                    normalizeWikimediaMinervaCollapsibleSections(parserInputClone);
                }
                var article = new Readability(uri, parserInputClone, {
                    // https://github.com/mozilla/gecko-dev/blob/246928d59c6c11e1c3b3b0a6b00534bfc075e3c4/toolkit/components/reader/ReaderMode.jsm#L21-L31
                classesToPreserve: [
                    "caption", "emoji", "hidden", "invisible", "sr-only", "visually-hidden", "visuallyhidden", "wp-caption", "wp-caption-text", "wp-smiley"
                ],
                    charThreshold: ##CHAR_THRESHOLD##}).parse();
                
                if (article === null) {
                    if (document.body) {
                        document.body.dataset.mnbReaderModeAvailable = 'false';
                        document.body.dataset.isNextLoadInReaderMode = 'false';
                    }
                    window.webkit.messageHandlers.readabilityModeUnavailable.postMessage({
                        pageURL: loc.href,
                        windowURL: windowURL,
                    })
                } else {
                    let title = DOMPurify.sanitize(article.title)
                    let byline = DOMPurify.sanitize(article.byline)
                    let publishedTime = DOMPurify.sanitize(formatReadabilityPublishedTime(article.publishedTime || ''))
                    var content = DOMPurify.sanitize(article.content)
                    let contentIsInternal = isInternalURL(uri.spec)
                    let viewOriginalHref = DOMPurify.sanitize(String(uri.spec)).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                    let viewOriginal = contentIsInternal ? '' : `<a class="reader-view-original" href="${viewOriginalHref}">View Original</a>`
                    let metaItems = [
                        publishedTime ? `<span id="reader-publication-date">${publishedTime}</span>` : '',
                        viewOriginal,
                    ].filter(Boolean)
                    let metaLine = metaItems.length ? `<div id="reader-meta-line" class="byline-meta-line">${metaItems.join('<span class="reader-meta-divider">·</span>')}</div>` : ''
                    if (globalThis.manabi_debugDiagnosticsEnabled) {
                    window.webkit?.messageHandlers?.print?.postMessage({
                        message: '# BYLINE readabilityParsed.js',
                        pageURL: loc.href,
                        byline: byline || null,
                        bylineBytes: byline.length,
                        publishedTime: publishedTime || null,
                        hasMetaLine: metaLine.length > 0,
                        hasViewOriginal: viewOriginal.length > 0,
                    })
                    }
                    
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
                ${metaLine}
            </div>
            <div id="reader-header-actions"></div>
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

                    // 0 is innermost.
                    // Currently only supports optional [shadowRoot][shadowRoot][iframe] nesting
                    /*
                     let layer0FrameSelector = closestFrameSelector()
                     let layer1ShadowRootSelector = getShadowRootSelector(layer0FrameSelector ? layer0FrameSelector.node : document)
                     let layer2ShadowRootSelector = layer1ShadowRootSelector ? closestShadowRootSelector(layer1 layer1ShadowRootSelector.node) : null
                     */

                    if (document.body) {
                        if (content) {
                            document.body.dataset.mnbReaderModeAvailable = 'true';
                            document.body.dataset.mnbReaderModeAvailableFor = loc.href;
                            
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
                            document.body.dataset.mnbReaderModeAvailable = 'false';
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                            delete document.body.dataset.mnbReaderModeAvailableFor;

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
    window.manabi_readability = manabi_readability;
    let manabi_requestAutomaticReadability = function (reason) {
        let handler = window.webkit?.messageHandlers?.readabilityNeedsUpdate;
        if (!handler) {
            return;
        }
        try {
            handler.postMessage({
                reason: reason,
                windowURL: getOriginURL(),
            });
        } catch (_error) {
            // Ignore native bridge errors; Readability availability is opportunistic.
        }
    }

    let manabi_debouncedReadability = manabi_debounce(function () {
        if (document.body?.dataset?.mnbReaderModeAvailableFor !== window.location.href) {
            manabi_requestAutomaticReadability('mutation')
        }
    } , 3 * 1000)

    let manabi_observedReadabilityHref = window.location.href;
    let manabi_requestReadabilityForLocationChange = function (reason) {
        let previousHref = manabi_observedReadabilityHref;
        let currentHref = window.location.href;
        if (previousHref === currentHref) {
            return;
        }
        manabi_observedReadabilityHref = currentHref;
        if (document.body) {
            document.body.dataset.mnbReaderModeAvailable = 'false';
            document.body.dataset.isNextLoadInReaderMode = 'false';
            delete document.body.dataset.mnbReaderModeAvailableFor;
        }
        manabi_requestAutomaticReadability(reason);
        setTimeout(() => {
            if (manabi_observedReadabilityHref === window.location.href) {
                manabi_requestAutomaticReadability(reason + '-settled');
            }
        }, 500);
        setTimeout(() => {
            if (manabi_observedReadabilityHref === window.location.href) {
                manabi_requestAutomaticReadability(reason + '-late');
            }
        }, 1500);
    }

    let manabi_installReadabilityLocationObserver = function () {
        if (window.manabi_readabilityLocationObserverInstalled) {
            return;
        }
        window.manabi_readabilityLocationObserverInstalled = true;
        let wrapHistoryMethod = function (methodName) {
            let original = history[methodName];
            if (typeof original !== 'function') {
                return;
            }
            history[methodName] = function () {
                let result = original.apply(this, arguments);
                setTimeout(() => {
                    manabi_requestReadabilityForLocationChange(methodName);
                }, 0);
                return result;
            }
        }
        wrapHistoryMethod('pushState');
        wrapHistoryMethod('replaceState');
        window.addEventListener('popstate', () => {
            setTimeout(() => {
                manabi_requestReadabilityForLocationChange('popstate');
            }, 0);
        });
    }

    let initialize = function () {
        if (window.location.protocol === 'about:') {
            return
        }
        manabi_installReadabilityLocationObserver()
        
        var observer = new MutationObserver(function (mutations) {
            mutations.forEach(function(mutation) {
                if (mutation.type === 'attributes' && mutation.attributeName === 'class') {
                    for (cls of mutation.target.classList) {
                        if (cls.startsWith('mnb-')) {
                            return
                        }
                    }
                }
                if (mutation.type === 'attributes' && mutation.attributeName.startsWith('data-mnb-')) {
                    return
                }
                if ((mutation.target.textContent?.length || 0) > 1) {
                    manabi_debouncedReadability()
                }
            })
        })
        let observerConfig = {attributes: true, childList: true,  characterData: true}
        
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
                manabi_requestAutomaticReadability('page-load')
                initializeFrameStateRefreshes()
                observer.observe(document, observerConfig)
            }
        } else {
            document.addEventListener('DOMContentLoaded', (event) => {
                if (!hasCalledReadabilityOnPageLoad) {
                    hasCalledReadabilityOnPageLoad = true
                    manabi_requestAutomaticReadability('dom-content-loaded')
                    initializeFrameStateRefreshes()
                    observer.observe(document, observerConfig)
                }
            })
            document.addEventListener('readystatechange', () => {
                if (document.readyState === 'complete' && !hasCalledReadabilityOnPageLoad) {
                    hasCalledReadabilityOnPageLoad = true
                    manabi_requestAutomaticReadability('ready-state-complete')
                    initializeFrameStateRefreshes()
                    observer.observe(document, observerConfig)
                }
            })
        }
        
        let oldOnShow = window.onpageshow
        window.onpageshow = function(event) {
            if (event.persisted) {
                // From back/forward cache... Re-run initialization
                manabi_requestAutomaticReadability('page-show-persisted')
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
