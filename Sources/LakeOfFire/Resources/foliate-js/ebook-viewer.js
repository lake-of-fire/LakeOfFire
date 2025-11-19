// Global timers for side-nav chevron fades
import './view.js'
import {
    createTOCView
} from './ui/tree.js'
import {
    Overlayer
} from '../foliate-js/overlayer.js'
import { NavigationHUD } from './ebook-viewer-nav.js'

const DEFAULT_RUBY_FONT_STACK = `'Hiragino Kaku Gothic ProN', 'Hiragino Sans', system-ui`;

window.onerror = function(msg, source, lineno, colno, error) {
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: msg,
        source: source,
        lineno: lineno,
        colno: colno,
        error: String(error)
    });
};

window.onunhandledrejection = function(event) {
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: event.reason?.message ?? "Unhandled rejection",
        source: window.location.href,
        lineno: null,
        colno: null,
        error: event.reason?.stack ?? String(event.reason)
    });
};

function forwardShadowErrors(root) {
    if (!root) return;
    root.addEventListener('error', e => {
        window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
            message: e.message || e.error?.message || 'Shadow-DOM error',
            source: window.location.href,
            lineno: e.lineno || 0,
            colno: e.colno || 0,
            error: e.error?.stack || String(e.error || e)
        });
    });
    root.addEventListener('unhandledrejection', e => {
        window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
            message: e.reason?.message || 'Shadow-DOM unhandled rejection',
            source: window.location.href,
            lineno: 0,
            colno: 0,
            error: e.reason?.stack || String(e.reason)
        });
    });
}

let pendingHideNavigationState = null;
const applyLocalHideNavigationDueToScroll = (shouldHide) => {
    pendingHideNavigationState = !!shouldHide;
    if (globalThis.reader?.setHideNavigationDueToScroll) {
        globalThis.reader.setHideNavigationDueToScroll(pendingHideNavigationState);
        pendingHideNavigationState = null;
    }
};
globalThis.manabiSetHideNavigationDueToScroll = applyLocalHideNavigationDueToScroll;

globalThis.manabiToggleReaderTableOfContents = () => {
    try {
        if (globalThis.reader?.toggleTableOfContents) {
            globalThis.reader.toggleTableOfContents();
        }
    } catch (error) {
        console.error('Failed to toggle table of contents', error);
    }
};

const postNavigationChromeVisibility = (shouldHide, { source, direction } = {}) => {
    applyLocalHideNavigationDueToScroll(!!shouldHide);
    try {
        window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
            hideNavigationDueToScroll: !!shouldHide,
            source: source ?? null,
            direction: direction ?? null,
        });
    } catch (error) {
        console.error('Failed to notify native navigation chrome visibility', error);
    }
};

// Factory for replaceText with isCacheWarmer support
const makeReplaceText = (isCacheWarmer) => async (href, text, mediaType) => {
    if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html' /* && mediaType !== 'application/xml'*/ ) {
        return text;
    }
    const headers = {
        "Content-Type": mediaType,
        "X-Replaced-Text-Location": href,
        "X-Content-Location": globalThis.reader.view.ownerDocument.defaultView.top.location.href,
    };
    if (isCacheWarmer) {
        headers['X-Is-Cache-Warmer'] = 'true';
    }
    const response = await fetch('ebook://ebook/process-text', {
        method: "POST",
        mode: "cors",
        cache: "no-cache",
        headers: headers,
        body: text
    })
    try {
        if (!response.ok) {
            throw new Error(`HTTP error, status = ${response.status}`)
        }
        let html = await response.text()
        if (isCacheWarmer && html.replace) {
            html = html.replace(/<body\s/i, "<body data-is-cache-warmer='true' ")
        }
        return html
    } catch (error) {
        console.error("Error replacing text:", error)
        return text
    }
}

// https://learnersbucket.com/examples/interview/debouncing-with-leading-and-trailing-options/
const debounce = (fn, delay) => {
    let timeout;
    let isLeadingInvoked = false;
    
    return function(...args) {
        const context = this;
        
        if (!timeout) {
            fn.apply(context, args);
            isLeadingInvoked = true;
            
            timeout = setTimeout(() => {
                timeout = null;
                if (!isLeadingInvoked) {
                    fn.apply(context, args);
                }
            }, delay);
        } else {
            isLeadingInvoked = false;
        }
    }
};

const isZip = async file => {
    const arr = new Uint8Array(await file.slice(0, 4).arrayBuffer())
    return arr[0] === 0x50 && arr[1] === 0x4b && arr[2] === 0x03 && arr[3] === 0x04
}

const makeZipLoader = async (file, isCacheWarmer) => {
    const {
        configure,
        ZipReader,
        BlobReader,
        TextWriter,
        BlobWriter
    } =
    await import('./vendor/zip.js')
    configure({
        useWebWorkers: false
    })
    const reader = new ZipReader(new BlobReader(file))
    const entries = await reader.getEntries()
    const map = new Map(entries.map(entry => [entry.filename, entry]))
    const load = f => (name, ...args) =>
    map.has(name) ? f(map.get(name), ...args) : null
    const loadText = load(entry => entry.getData(new TextWriter()))
    const loadBlob = load((entry, type) => entry.getData(new BlobWriter(type)))
    const getSize = name => map.get(name)?.uncompressedSize ?? 0
    //    const wrappedReplaceText = ((href, text, mediaType) => {
    //        replaceText(href, text, mediaType, isCacheWarmer)
    //    })
    const replaceText = makeReplaceText(isCacheWarmer)
    return {
        entries,
        loadText,
        loadBlob,
        getSize,
        replaceText
    }
}

const getFileEntries = async entry => entry.isFile ? entry :
(await Promise.all(Array.from(
                              await new Promise((resolve, reject) => entry.createReader()
                                                .readEntries(entries => resolve(entries), error => reject(error))),
                              getFileEntries))).flat()

const isCBZ = ({
    name,
    type
}) =>
type === 'application/vnd.comicbook+zip' || name.endsWith('.cbz')

const isFB2 = ({
    name,
    type
}) =>
type === 'application/x-fictionbook+xml' || name.endsWith('.fb2')

const isFBZ = ({
    name,
    type
}) =>
type === 'application/x-zip-compressed-fb2' ||
name.endsWith('.fb2.zip') || name.endsWith('.fbz')

const getView = async (file, isCacheWarmer) => {
    let book
    if (!file.size) throw new Error('File not found')
        else if (await isZip(file)) {
            const loader = await makeZipLoader(file, isCacheWarmer)
            if (isCBZ(file)) {
                throw new Error('File format not yet supported')
                //            const { makeComicBook } = await import('./comic-book.js')
                //            book = makeComicBook(loader, file)
            } else if (isFBZ(file)) {
                throw new Error('File format not yet supported')
                //            const { makeFB2 } = await import('./fb2.js')
                //            const { entries } = loader
                //            const entry = entries.find(entry => entry.filename.endsWith('.fb2'))
                //            const blob = await loader.loadBlob((entry ?? entries[0]).filename)
                //            book = await makeFB2(blob)
            } else {
                const {
                    EPUB
                } = await import('./epub.js')
                book = await new EPUB(loader).init()
            }
        } else {
            throw new Error('File format not yet supported')
            //        const { isMOBI, MOBI } = await import('./mobi.js')
            //        if (await isMOBI(file)) {
            //            const fflate = await import('./vendor/fflate.js')
            //            book = await new MOBI({ unzlib: fflate.unzlibSync }).open(file)
            //        } else if (isFB2(file)) {
            //            const { makeFB2 } = await import('./fb2.js')
            //            book = await makeFB2(file)
            //        }
        }
    if (!book) throw new Error('File type not supported')
        const view = document.createElement('foliate-view')
        view.dataset.isCache = isCacheWarmer;
    //if (!isCacheWarmer) {
    document.body.append(view);
    forwardShadowErrors(view.shadowRoot);
    //}
    if (isCacheWarmer) {
        view.style.display = 'none'
        view.style.contain = 'strict'
        view.style.position = 'absolute'
        view.style.left = '-9001px'
        view.style.width = 0
        view.style.height = 0
        view.style.pointerEvents = 'none'
    }
    await view.open(book, isCacheWarmer)
    
    // Hide scrollbars on the scrolling container inside foliate-paginator's shadow DOM
    const paginator = view.shadowRoot?.querySelector('foliate-paginator');
    if (paginator?.shadowRoot) {
        const style = document.createElement('style');
        style.textContent = `
        #container {
            scrollbar-width: none !important;         /* Firefox */
            -ms-overflow-style: none !important;      /* IE/Edge */
        }
        #container::-webkit-scrollbar {
            display: none !important;                 /* WebKit (macOS/iOS) */
            width: 0 !important;
            height: 0 !important;
        }
    `;
        paginator.shadowRoot.appendChild(style);
        
        const sideNavWidth = 32;
        document.documentElement.style.setProperty('--side-nav-width', `${sideNavWidth}px`);
        // Also set --side-nav-width on the inner view, so it propagates into the iframe's shadow DOM.
        const syncSideNavWidth = () => {
            const width = getComputedStyle(document.body)
            .getPropertyValue('--side-nav-width').trim();
            if (view) {
                view.style.setProperty('--side-nav-width', width);
                // Also update the renderer's CSS variable, if setSideNavWidth exists
                if (view.renderer && typeof view.renderer.setSideNavWidth === "function") {
                    view.renderer.setSideNavWidth(width);
                }
            }
        };
        window.addEventListener('resize', syncSideNavWidth);
        syncSideNavWidth();
    }
    
    return view
}

const getCSSForBookContent = ({
    spacing,
    justify,
    hyphenate
}) => `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: light dark;
        cursor: inherit;
    }
    /* https://github.com/whatwg/html/issues/5426 */
    @media (prefers-color-scheme: dark) {
        a:link {
            color: lightblue;
        }
    }
    p, li, blockquote, dd {
        line-height: ${spacing};
        text-align: ${justify ? 'justify' : 'start'};
        -webkit-hyphens: ${hyphenate ? 'auto' : 'manual'};
        hyphens: ${hyphenate ? 'auto' : 'manual'};
        -webkit-hyphenate-limit-before: 3;
        -webkit-hyphenate-limit-after: 2;
        -webkit-hyphenate-limit-lines: 2;
        hanging-punctuation: allow-end last;
        widows: 2;
    }
    /* prevent the above from overriding the align attribute */
    [align="left"] { text-align: left; }
    [align="right"] { text-align: right; }
    [align="center"] { text-align: center; }
    [align="justify"] { text-align: justify; }

    pre {
        white-space: pre-wrap !important;
    }
    aside[epub|type~="endnote"],
    aside[epub|type~="footnote"],
    aside[epub|type~="note"],
    aside[epub|type~="rearnote"] {
        display: none;
    }

    body * {
        background: inherit !important;
        color: inherit !important;
    }

    body:not(.manabi-tracking-section-geometries-baked):not(.manabi-tracking-section-measuring) .manabi-tracking-section {
        display: none !important;
    }

    body.manabi-tracking-section-measuring .manabi-tracking-section {
        display: block !important;
        visibility: hidden !important;
    }

    body.manabi-tracking-section-measuring manabi-container,
    body.manabi-tracking-section-measuring manabi-segment {
        content-visibility: visible !important;
    }

    .manabi-tracking-section {
        contain: initial !important;
    }

    body *:not(rt) {
        font-family: inherit !important;
        font-weight: inherit !important;
    }

    body *:not(.manabi-tracking-container *):not(manabi-segment *):not(ruby *) {
        /* prevent height: 100% type values from breaking getBoundingClientRect layout in paginator */
        height: inherit !important;
    }
    body.reader-is-single-media-element-without-text *:not(.manabi-tracking-container *):not(manabi-segment *) {
        max-height: 99vh;
    }
/*
reader-sentinel {
  position: relative;
  display: inline; /*-block;*/
  width: 4px !important;
  height: 4px !important;
  opacity: 1 !important;
  pointer-events: none !important;
  contain: strict;
  background: red !important;
}
*/
    reader-sentinel {
         position: relative !important;
         display: inline-block !important;
         width: 0 !important;
         height: 0 !important;
         padding: 0 !important;
         contain: strict !important;
         pointer-events: none !important;
         opacity: 0 !important;
         vertical-align: bottom !important;
         break-before: avoid !important;
         break-after: avoid !important;
         break-inside: avoid !important;
    }
`

const $ = document.querySelector.bind(document)

const locales = 'en'
const percentFormat = new Intl.NumberFormat(locales, {
    style: 'percent'
})

class Reader {
    #logScrubDiagnostic(_event, _payload = {}) {}
    #show(btn, show = true) {
        if (show) {
            btn.hidden = false;
            btn.style.visibility = 'visible';
            btn.style.display = '';
        } else {
            btn.hidden = true;
            btn.style.visibility = 'hidden';
            btn.style.display = 'none';
        }
    }
    setLoadingIndicator(visible) {
        document.body.classList.toggle('loading', !!visible);
    }
    #tocView
    #chevronFadeTimers = {
        l: null,
        r: null
    }
    #progressSlider = null
    #progressScrubState = null
    #handleProgressSliderPointerDown = (event) => {
        if (!this.#progressSlider) return;
        if (event.pointerType === 'mouse' && event.button !== 0) return;
        if (this.#progressScrubState) {
            this.#finalizeProgressScrubSession({ cancel: true });
        }
        this.#progressSlider.setPointerCapture?.(event.pointerId);
        const originDescriptor = this.navHUD?.getCurrentDescriptor();
        this.#progressScrubState = {
            pointerId: event.pointerId,
            pendingEnd: false,
            cancelRequested: false,
            timeoutId: null,
            releaseFraction: null,
        };
        this.navHUD?.beginProgressScrubSession(originDescriptor);
        this.#logScrubDiagnostic('pointer-down', {
            pointerId: event.pointerId,
            pointerType: event.pointerType,
            sliderValue: Number(this.#progressSlider?.value ?? NaN),
        });
    }
    #handleProgressSliderPointerUp = (event) => {
        if (!this.#progressScrubState || this.#progressScrubState.pointerId !== event.pointerId) return;
        this.#progressScrubState.releaseFraction = Number(this.#progressSlider?.value ?? NaN);
        this.#progressSlider?.releasePointerCapture?.(event.pointerId);
        this.#logScrubDiagnostic('pointer-up', {
            pointerId: event.pointerId,
            sliderValue: Number(this.#progressSlider?.value ?? NaN),
        });
        this.#requestProgressScrubEnd(false);
    }
    #handleProgressSliderPointerCancel = (event) => {
        if (!this.#progressScrubState || this.#progressScrubState.pointerId !== event.pointerId) return;
        this.#progressScrubState.releaseFraction = Number(this.#progressSlider?.value ?? NaN);
        this.#progressSlider?.releasePointerCapture?.(event.pointerId);
        this.#logScrubDiagnostic('pointer-cancel', {
            pointerId: event.pointerId,
            sliderValue: Number(this.#progressSlider?.value ?? NaN),
        });
        this.#requestProgressScrubEnd(true);
    }
    hasLoadedLastPosition = false
    markedAsFinished = false;
    lastPercentValue = null;
    lastPageEstimate = null;
    lastKnownFraction = 0;
    jumpUnit = 'percent';
    #jumpInput = null;
    #jumpButton = null;
    #jumpUnitSelect = null;
    style = {
        spacing: 1.4,
        justify: true,
        hyphenate: true,
    }
    annotations = new Map()
    annotationsByValue = new Map()
    openSideBar() {
        $('#dimming-overlay').classList.add('show')
        $('#side-bar').classList.add('show')
        if (this.#tocView?.setCurrentHref && this.view?.renderer?.tocItem?.href) {
            this.#tocView.setCurrentHref(this.view.renderer.tocItem.href)
        }
    }
    closeSideBar() {
        $('#dimming-overlay').classList.remove('show')
        $('#side-bar').classList.remove('show')
    }
    toggleTableOfContents() {
        const sideBar = document.getElementById('side-bar');
        if (!sideBar) return;
        if (sideBar.classList.contains('show')) {
            this.closeSideBar();
        } else {
            this.openSideBar();
        }
    }
    setHideNavigationDueToScroll(shouldHide) {
        this.navHUD?.setHideNavigationDueToScroll(shouldHide);
    }
    constructor() {
        this.navHUD = new NavigationHUD({
            formatPercent: value => percentFormat.format(value),
            getRenderer: () => this.view?.renderer,
            onJumpRequest: descriptor => this.#goToDescriptor(descriptor),
        });
        $('#side-bar-close-button').addEventListener('click', () => {
            this.closeSideBar()
        })
        $('#dimming-overlay').addEventListener('click', () => this.closeSideBar())
    }
    async open(file) {
        this.setLoadingIndicator(true);
        this.hasLoadedLastPosition = false
        this.view = await getView(file, false)
        // this.view.renderer.setAttribute('animated', true) // Flows top to bottom instead of like a book...
        if (typeof window.initialLayoutMode !== 'undefined') {
            this.view.renderer.setAttribute('flow', window.initialLayoutMode)
        }
        this.view.renderer.addEventListener('goTo', this.#onGoTo.bind(this))
        this.view.renderer.addEventListener('didDisplay', this.#onDidDisplay.bind(this))
        this.view.addEventListener('load', this.#onLoad.bind(this))
        this.view.addEventListener('relocate', this.#onRelocate.bind(this))
        
        const {
            book
        } = this.view
        this.bookDir = book.dir || 'ltr';
        this.isRTL = this.bookDir === 'rtl';
        document.body.dir = this.bookDir;
        this.navHUD?.setIsRTL(this.isRTL);
        this.navHUD?.setPageTargets(book.pageList ?? []);
        this.view.renderer.setStyles?.(getCSSForBookContent(this.style))
        //        this.view.renderer.next()
        
        $('#nav-bar').style.visibility = 'visible'
        this.buttons = {
            prev: document.getElementById('btn-prev-chapter'),
            next: document.getElementById('btn-next-chapter'),
            finish: document.getElementById('btn-finish'),
            restart: document.getElementById('btn-restart'),
        };
        // Hide all other nav buttons except spinners
        for (const btn of Object.values(this.buttons)) {
            btn && (btn.hidden = true);
        }
        
        // Flip chevron icons for RTL books
        if (this.isRTL) {
            const flipChevron = (btn, leftArrow) => {
                const path = btn.querySelector('path');
                if (path) {
                    path.setAttribute('d', leftArrow ?
                                      'M 15 6 L 9 12 L 15 18' // left chevron (◀)
                                      :
                                      'M 9 6 L 15 12 L 9 18'); // right chevron (▶)
                }
            };
            
            flipChevron(this.buttons.prev, false); // ▶
            flipChevron(this.buttons.next, true); // ◀
            
            // Swap label/icon order for chapter buttons in RTL
            // Ensure "Next Chapter" shows "< Next Chapter"
            const nextBtn = this.buttons.next;
            const nextLabel = nextBtn.querySelector('.button-label');
            const nextIcon = nextBtn.querySelector('svg');
            if (nextIcon && nextLabel && nextIcon !== nextLabel.previousSibling) {
                nextBtn.insertBefore(nextIcon, nextLabel);
            }
            
            // Ensure "Previous Chapter" shows "Previous Chapter >"
            const prevBtn = this.buttons.prev;
            const prevLabel = prevBtn.querySelector('.button-label');
            const prevIcon = prevBtn.querySelector('svg');
            if (prevIcon && prevLabel && prevLabel !== prevIcon.previousSibling) {
                prevBtn.insertBefore(prevLabel, prevIcon);
            }
            
            // Spinner placement logic for RTL
            // For prev: spinner after label (right side, where chevron is)
            // For next: spinner before label (left side, where chevron is)
            if (this.buttons.prev) {
                this.buttons.prev._spinnerAfterLabel = true;
            }
            if (this.buttons.next) {
                this.buttons.next._spinnerAfterLabel = false;
            }
        } else {
            // LTR: spinner replaces icon (before label for prev, after label for next)
            if (this.buttons.prev) {
                this.buttons.prev._spinnerAfterLabel = false;
            }
            if (this.buttons.next) {
                this.buttons.next._spinnerAfterLabel = false;
            }
        }
        Object.values(this.buttons).forEach(btn =>
                                            btn.addEventListener('click', this.#onNavButtonClick.bind(this))
                                            );
        // Side-nav scroll handlers
        const leftSideBtn = document.getElementById('btn-scroll-left');
        if (leftSideBtn) leftSideBtn.addEventListener('click', async () => await this.view.goLeft());
        const rightSideBtn = document.getElementById('btn-scroll-right');
        if (rightSideBtn) rightSideBtn.addEventListener('click', async () => await this.view.goRight());
        
        // Immediate tap feedback for side-nav chevrons on iOS/touch
        document.querySelectorAll('.side-nav').forEach(nav => {
            nav.addEventListener('touchstart', () => {
                nav.classList.add('pressed');
            }, {
                passive: true
            });
            nav.addEventListener('touchend', () => {
                nav.classList.remove('pressed');
            });
            nav.addEventListener('touchcancel', () => {
                nav.classList.remove('pressed');
            });
        });
        
        // Side-nav opacity wiring
        this.view.addEventListener('sideNavChevronOpacity', e => {
            const l = document.querySelector('#btn-scroll-left .icon');
            const r = document.querySelector('#btn-scroll-right .icon');
            
            const FADER_DELAY = 180;
            const fadeWithHold = (elem, value, key) => {
                if (!elem) return;
                
                clearTimeout(this.#chevronFadeTimers[key]);
                this.#chevronFadeTimers[key] = null;
                
                // Show chevron at full opacity
                if (Number(value) >= 1) {
                    elem.style.removeProperty('opacity');
                    elem.classList.add('chevron-visible');
                    return;
                }
                
                // Show chevron at partial opacity
                if (Number(value) > 0) {
                    elem.classList.remove('chevron-visible');
                    elem.style.opacity = value;
                    return;
                }
                
                // Hide chevron, but only after a delay and only if currently visible
                if (elem.classList.contains('chevron-visible')) {
                    this.#chevronFadeTimers[key] = setTimeout(() => {
                        elem.classList.remove('chevron-visible');
                        elem.style.removeProperty('opacity');
                        this.#chevronFadeTimers[key] = null;
                    }, FADER_DELAY);
                } else {
                    // Already hidden: do nothing
                    elem.style.removeProperty('opacity');
                    elem.classList.remove('chevron-visible');
                }
            };
            
            fadeWithHold(l, e.detail.leftOpacity, 'l');
            fadeWithHold(r, e.detail.rightOpacity, 'r');
        });
        // Listen for resetSideNavChevrons custom event to reset chevrons
        document.addEventListener('resetSideNavChevrons', () => this.#resetSideNavChevrons());
        
        // Legacy layout support: reorder toolbar children only if the old stacks exist
        const navBar = document.getElementById('nav-bar');
        const leftStack = document.getElementById('left-stack');
        const rightStack = document.getElementById('right-stack');
        const progressWrapper = document.getElementById('progress-wrapper');
        if (navBar && leftStack && rightStack && progressWrapper) {
            navBar.innerHTML = '';
            if (this.isRTL) {
                navBar.append(rightStack, progressWrapper, leftStack);
            } else {
                navBar.append(leftStack, progressWrapper, rightStack);
            }
        }
        
        const slider = $('#progress-slider')
        this.#progressSlider = slider
        slider.dir = book.dir
        const debouncedGoToFraction = debounce(e => {
            this.view.goToFraction(parseFloat(e.target.value))
        }, 250);
        slider.addEventListener('input', debouncedGoToFraction)
        slider.addEventListener('pointerdown', this.#handleProgressSliderPointerDown)
        slider.addEventListener('pointerup', this.#handleProgressSliderPointerUp)
        slider.addEventListener('pointercancel', this.#handleProgressSliderPointerCancel)
        
        // Section ticks
        const sizes = book.sections.filter(s => s.linear !== 'no').map(s => s.size)
        const total = sizes.reduce((a, b) => a + b, 0)
        let sum = 0
        // Calculate all tick positions as fractions
        let ticks = [];
        for (const size of sizes.slice(0, -1)) {
            sum += size;
            ticks.push(sum / total);
        }
        if (sizes.length >= 50) {
            // Collapse ticks that are close to each other, never collapse more than those within that window.
            const THRESHOLD = 0.01;
            let collapsed = [];
            let group = [];
            for (let i = 0; i < ticks.length; ++i) {
                group.push(ticks[i]);
                // If next tick is far enough, close group
                if (i === ticks.length - 1 || Math.abs(ticks[i + 1] - ticks[i]) > THRESHOLD) {
                    // Collapse group if there's more than one tick in threshold
                    if (group.length > 1) {
                        // Pick the tick closest to the middle of the group
                        const avg = group.reduce((a, b) => a + b, 0) / group.length;
                        let closest = group[0];
                        let minDist = Math.abs(avg - closest);
                        for (const t of group) {
                            const dist = Math.abs(avg - t);
                            if (dist < minDist) {
                                minDist = dist;
                                closest = t;
                            }
                        }
                        collapsed.push(closest);
                    } else {
                        collapsed.push(group[0]);
                    }
                    group = [];
                }
            }
            ticks = collapsed;
        }
        // Clear any previous ticks
        const tickMarks = $('#tick-marks');
        tickMarks.innerHTML = '';
        for (const tick of ticks) {
            const option = document.createElement('option');
            option.value = tick;
            tickMarks.append(option);
        }
        
        slider.style.setProperty('--value', slider.value);
        slider.style.setProperty('--min', slider.min == '' ? '0' : slider.min);
        slider.style.setProperty('--max', slider.max == '' ? '100' : slider.max);
        slider.addEventListener('input', () => slider.style.setProperty('--value', slider.value));
        
        // Percent jump input/button wiring
        const percentInput = document.getElementById('percent-jump-input');
        const percentButton = document.getElementById('percent-jump-button');
        const jumpUnitSelect = document.getElementById('jump-unit-select');
        this.#jumpInput = percentInput;
        this.#jumpButton = percentButton;
        this.#jumpUnitSelect = jumpUnitSelect;
        this.jumpUnit = jumpUnitSelect?.value === 'page' ? 'page' : 'percent';
        this.lastPageEstimate = null;
        this.#updateJumpUnitAvailability();
        this.#syncJumpInputWithState();
        
        const handleJumpInputChange = () => {
            const value = parseFloat(percentInput.value);
            percentButton.disabled = !this.#isJumpInputValueValid(value);
        };
        percentInput.addEventListener('input', handleJumpInputChange);
        
        jumpUnitSelect?.addEventListener('change', () => {
            const nextUnit = jumpUnitSelect.value === 'page' ? 'page' : 'percent';
            if (this.jumpUnit === nextUnit) return;
            const previousUnit = this.jumpUnit;
            const currentValue = parseFloat(percentInput.value);
            const converted = this.#convertJumpInputValue(currentValue, previousUnit, nextUnit);
            this.jumpUnit = nextUnit;
            this.#syncJumpInputWithState(converted);
            percentButton.disabled = true;
        });
        
        percentButton.addEventListener('click', () => {
            const value = parseFloat(percentInput.value);
            if (!this.#isJumpInputValueValid(value)) return;
            if (this.jumpUnit === 'percent') {
                this.lastPercentValue = value;
                this.lastKnownFraction = value / 100;
                percentButton.disabled = true;
                this.view.goToFraction(value / 100);
            } else {
                const totalPages = this.lastPageEstimate?.total;
                const fraction = this.#fractionFromPage(value, totalPages);
                if (fraction == null) return;
                this.lastPercentValue = Math.round(fraction * 100);
                this.lastKnownFraction = fraction;
                percentButton.disabled = true;
                this.view.goToFraction(fraction);
            }
        });
        
        document.addEventListener('keydown', this.#handleKeydown.bind(this))
        
        const processTouchStart = function(event) {
            // Ignore touches inside foliate-js viewer iframe
            if (event.target && event.target.ownerDocument !== document) return
                
                window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
                    touchedEntryWithElementId: null,
                    wasAlreadySelected: false,
                })
                }
        document.addEventListener('touchstart', processTouchStart, {
            passive: true
        })
        document.addEventListener('mousedown', processTouchStart, {
            passive: true
        })
        
        
        const title = book.metadata?.title ?? 'Untitled Book'
        document.title = title
        $('#side-bar-title').innerText = title
        const author = book.metadata?.author
        let authorText = typeof author === 'string' ? author :
        author
        ?.map(author => typeof author === 'string' ? author : author.name)
        ?.join(', ') ??
        ''
        $('#side-bar-author').innerText = authorText
        window.webkit.messageHandlers.pageMetadataUpdated.postMessage({
            'title': title,
            'author': authorText,
            'url': window.top.location.href
        })
        
        Promise.resolve(book.getCover?.())?.then(blob => {
            blob ? $('#side-bar-cover').src = URL.createObjectURL(blob) : null
        })
        
        const toc = book.toc
        if (toc) {
            this.#tocView = createTOCView(toc, async (href) => {
                await this.view.goTo(href).catch(e => console.error(e))
                this.closeSideBar()
            })
            $('#toc-view').append(this.#tocView.element)
        }
        
        // load and show highlights embedded in the file by Calibre
        const bookmarks = await book.getCalibreBookmarks?.()
        if (bookmarks) {
            const {
                fromCalibreHighlight
            } = await import('./epubcfi.js')
            for (const obj of bookmarks) {
                if (obj.type === 'highlight') {
                    const value = fromCalibreHighlight(obj)
                    const color = obj.style.which
                    const note = obj.notes
                    const annotation = {
                        value,
                        color,
                        note
                    }
                    const list = this.annotations.get(obj.spine_index)
                    if (list) list.push(annotation)
                        else this.annotations.set(obj.spine_index, [annotation])
                            this.annotationsByValue.set(value, annotation)
                            }
            }
            this.view.addEventListener('create-overlay', e => {
                const {
                    index
                } = e.detail
                const list = this.annotations.get(index)
                if (list)
                    for (const annotation of list)
                        this.view.addAnnotation(annotation)
                        })
            this.view.addEventListener('draw-annotation', e => {
                const {
                    draw,
                    annotation
                } = e.detail
                const {
                    color
                } = annotation
                draw(Overlayer.highlight, {
                    color
                })
            })
            this.view.addEventListener('show-annotation', e => {
                const annotation = this.annotationsByValue.get(e.detail.value)
                if (annotation.note) alert(annotation.note)
                    })
        }
    }
    
    async updateNavButtons() {
        // Remove any nav-spinner left over from finish/restart click
        document.querySelectorAll('.ispinner.nav-spinner').forEach(spinner => {
            const btn = spinner.closest('button');
            if (btn && btn._originalIcon) {
                spinner.replaceWith(btn._originalIcon);
                delete btn._originalIcon;
            }
            const label = btn.querySelector('.button-label');
            if (label) label.style.visibility = '';
        });
        if (!this.view?.renderer) return;
        const r = this.view.renderer;
        // Use new section start/end helpers if available
        const atSectionStart = typeof r.isAtSectionStart === "function" ? await r.isAtSectionStart() : false;
        const atSectionEnd = typeof r.isAtSectionEnd === "function" ? await r.isAtSectionEnd() : false;
        // Use public helpers to detect prev/next section
        const hasPrevSection = typeof r.getHasPrevSection === "function" ? await r.getHasPrevSection() : true;
        const hasNextSection = typeof r.getHasNextSection === "function" ? await r.getHasNextSection() : true;
        const shouldShowPrev = atSectionStart && hasPrevSection;
        const shouldShowNext = atSectionEnd && hasNextSection;
        
        this.#show(this.buttons.prev, shouldShowPrev);
        
        if (shouldShowNext) {
            this.#show(this.buttons.next, true);
            this.#show(this.buttons.finish, false);
            this.#show(this.buttons.restart, false);
        } else if (atSectionEnd && !hasNextSection) {
            this.#show(this.buttons.next, false);
            if (this.markedAsFinished) {
                this.#show(this.buttons.restart, true);
                this.#show(this.buttons.finish, false);
            } else {
                this.#show(this.buttons.finish, true);
                this.#show(this.buttons.restart, false);
            }
        } else {
            this.#show(this.buttons.next, false);
            this.#show(this.buttons.finish, false);
            this.#show(this.buttons.restart, false);
        }
        this.#setForwardChevronHint(shouldShowNext);
        
        // RTL/LTR logic for disabling/hiding side chevrons
        const btnScrollLeft = document.getElementById('btn-scroll-left');
        const btnScrollRight = document.getElementById('btn-scroll-right');
        if (btnScrollLeft && btnScrollRight) {
            if (this.isRTL) {
                // In RTL, left chevron = go forward, right chevron = go backward
                // Disable left at end, right at start
                btnScrollLeft.disabled = (atSectionEnd && !hasNextSection);
                btnScrollRight.disabled = (atSectionStart && !hasPrevSection);
            } else {
                // LTR, left chevron = backward, right chevron = forward
                // Disable left at start, right at end
                btnScrollLeft.disabled = (atSectionStart && !hasPrevSection);
                btnScrollRight.disabled = (atSectionEnd && !hasNextSection);
            }
        }
        
        // Consolidate restart icon SVG path update
        const restartBtn = this.buttons.restart;
        if (restartBtn) {
            const iconPath = restartBtn.querySelector('svg path');
            if (iconPath) {
                iconPath.setAttribute('d', 'M13 3a9 9 0 1 0 9 9h-2a7 7 0 1 1-7-7v3l4-4-4-4v3z');
                iconPath.setAttribute('fill', 'currentColor');
                iconPath.setAttribute('stroke', 'none');
            }
        }
        this.navHUD?.setNavContext({
            atSectionStart,
            atSectionEnd,
            hasPrevSection,
            hasNextSection,
            showingFinish: this.#isButtonVisible(this.buttons.finish),
            showingRestart: this.#isButtonVisible(this.buttons.restart),
        });
    }

    #isButtonVisible(button) {
        if (!button) return false;
        return !button.hidden && button.style.display !== 'none';
    }
    #setForwardChevronHint(shouldShow) {
        const forwardBtn = document.getElementById(this.isRTL ? 'btn-scroll-left' : 'btn-scroll-right');
        if (!forwardBtn) return;
        forwardBtn.classList.toggle('show-next', !!shouldShow);
        const icon = forwardBtn.querySelector('.icon');
        if (!icon) return;
        const isHovered = typeof forwardBtn.matches === 'function' ? forwardBtn.matches(':hover') : false;
        if (shouldShow) {
            icon.classList.add('chevron-visible');
            icon.style.opacity = '1';
        } else if (!forwardBtn.classList.contains('pressed') && !isHovered) {
            icon.classList.remove('chevron-visible');
            icon.style.opacity = '';
        }
    }
    #flashChevron(left) {
        this.view.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            detail: {
                leftOpacity: left ? '1' : '',
                rightOpacity: left ? '' : '1'
            }
        }))
        this.view.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            detail: {
                leftOpacity: left ? '0' : '',
                rightOpacity: left ? '' : '0'
            }
        }))
    }
    #requestProgressScrubEnd(cancelRequested) {
        if (!this.#progressScrubState) return;
        this.#progressScrubState.pendingEnd = true;
        this.#progressScrubState.cancelRequested = !!cancelRequested;
        if (this.#progressScrubState.timeoutId) {
            clearTimeout(this.#progressScrubState.timeoutId);
        }
        const cancel = this.#progressScrubState.cancelRequested;
        this.#logScrubDiagnostic('schedule-scrub-end', {
            cancel,
        });
        this.#progressScrubState.timeoutId = setTimeout(() => {
            this.#finalizeProgressScrubSession({ cancel });
        }, 400);
    }
    #finalizeProgressScrubSession({ cancel } = {}) {
        if (!this.#progressScrubState) return;
        if (this.#progressScrubState.timeoutId) {
            clearTimeout(this.#progressScrubState.timeoutId);
        }
        const descriptor = cancel ? null : this.navHUD?.getCurrentDescriptor();
        this.navHUD?.endProgressScrubSession(descriptor, {
            cancel,
            releaseFraction: this.#progressScrubState.releaseFraction,
        });
        this.#logScrubDiagnostic('finalize-scrub-session', {
            cancel,
        });
        this.#progressScrubState = null;
    }

    #isJumpInputValueValid(value) {
        if (typeof value !== 'number' || isNaN(value)) return false;
        if (this.jumpUnit === 'percent') {
            return value >= 0 && value <= 100 && value !== this.lastPercentValue;
        }
        const total = this.lastPageEstimate?.total;
        if (value < 1) return false;
        if (typeof total === 'number' && total > 0) {
            if (value > total) return false;
            const currentPage = this.lastPageEstimate?.current;
            if (typeof currentPage === 'number' && value === currentPage) return false;
        }
        return typeof total === 'number' && total > 0;
    }

    #fractionFromPage(pageNumber, totalPages) {
        if (typeof pageNumber !== 'number' || isNaN(pageNumber)) return null;
        if (typeof totalPages !== 'number' || totalPages <= 0) return null;
        if (totalPages === 1) return 0;
        const clamped = Math.max(1, Math.min(totalPages, Math.round(pageNumber)));
        return (clamped - 1) / (totalPages - 1);
    }

    #convertJumpInputValue(value, fromUnit, toUnit) {
        if (typeof value !== 'number' || isNaN(value)) return null;
        if (fromUnit === toUnit) return value;
        const totalPages = this.lastPageEstimate?.total;
        if (fromUnit === 'percent' && toUnit === 'page') {
            if (!totalPages || totalPages <= 0) return null;
            if (totalPages === 1) return 1;
            const fraction = value / 100;
            if (!isFinite(fraction)) return null;
            const page = Math.round(fraction * (totalPages - 1)) + 1;
            return Math.max(1, Math.min(totalPages, page));
        }
        if (fromUnit === 'page' && toUnit === 'percent') {
            if (!totalPages || totalPages <= 1) return null;
            const clamped = Math.max(1, Math.min(totalPages, Math.round(value)));
            const fraction = (clamped - 1) / (totalPages - 1);
            return Math.max(0, Math.min(100, Math.round(fraction * 100)));
        }
        return null;
    }

    #syncJumpInputWithState(convertedValue = null) {
        const input = this.#jumpInput ?? document.getElementById('percent-jump-input');
        if (!input) return;
        const button = this.#jumpButton ?? document.getElementById('percent-jump-button');
        if (!this.#jumpInput) this.#jumpInput = input;
        if (!this.#jumpButton) this.#jumpButton = button;
        if (this.jumpUnit === 'percent') {
            input.min = 0;
            input.max = 100;
            input.step = 'any';
            if (typeof convertedValue === 'number' && !isNaN(convertedValue)) {
                input.value = convertedValue;
            } else if (typeof this.lastPercentValue === 'number') {
                input.value = this.lastPercentValue;
            }
        } else {
            input.min = 1;
            input.max = this.lastPageEstimate?.total ?? '';
            input.step = 1;
            if (typeof convertedValue === 'number' && !isNaN(convertedValue)) {
                input.value = convertedValue;
            } else if (this.lastPageEstimate?.current != null) {
                input.value = this.lastPageEstimate.current;
            } else {
                input.value = '';
            }
        }
        if (button) {
            button.disabled = true;
        }
    }

    #updateJumpUnitAvailability() {
        const select = this.#jumpUnitSelect ?? document.getElementById('jump-unit-select');
        if (!select) return;
        if (!this.#jumpUnitSelect) this.#jumpUnitSelect = select;
        const pageOption = Array.from(select.options).find(option => option.value === 'page');
        const hasPages = typeof this.lastPageEstimate?.total === 'number' && this.lastPageEstimate.total > 0;
        if (pageOption) {
            pageOption.disabled = !hasPages;
        }
        if (!hasPages && this.jumpUnit === 'page') {
            this.jumpUnit = 'percent';
            select.value = 'percent';
            this.#syncJumpInputWithState();
        }
    }
    async #handleKeydown(event) {
        const k = event.key;
        const renderer = this.view.renderer;
        const isRTL = this.isRTL;
        
        if (k === 'ArrowLeft' || k === 'h') {
            if (isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else if (!isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else {
                await this.view.goLeft();
                this.#flashChevron(true);
            }
        } else if (k === 'ArrowRight' || k === 'l') {
            if (isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else if (!isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else {
                await this.view.goRight();
                this.#flashChevron(false);
            }
        }
    }
    #onGoTo({
        willLoadNewIndex
    }) {
        this.setLoadingIndicator(true);
    }
    #onDidDisplay({}) {
        this.setLoadingIndicator(false);
    }
    #onLoad({
        detail: {
            doc
        }
    }) {
        doc.addEventListener('keydown', this.#handleKeydown.bind(this))
        this.#ensureRubyFontOverride(doc)
        window.webkit.messageHandlers.updateCurrentContentPage.postMessage({
            topWindowURL: window.top.location.href,
            currentPageURL: doc.location.href,
        })
    }

    #ensureRubyFontOverride(doc) {
        try {
            const hostVar = document.documentElement?.style?.getPropertyValue('--manabi-ruby-font')?.trim();
            const stack = hostVar && hostVar.length > 0 ? hostVar : DEFAULT_RUBY_FONT_STACK;
            doc.documentElement?.style?.setProperty('--manabi-ruby-font', stack);
        } catch (error) {
            window.webkit?.messageHandlers?.print?.postMessage?.({
                message: 'RUBY_FONT_OVERRIDE_ERROR',
                error: String(error),
                pageURL: doc.location?.href ?? null
            });
        }
    }
    
    #resetSideNavChevrons() {
        // Clear any fade timers
        clearTimeout(this.#chevronFadeTimers.l);
        clearTimeout(this.#chevronFadeTimers.r);
        // Remove visible class & reset opacity immediately
        const leftIcon = document.querySelector('#btn-scroll-left .icon');
        const rightIcon = document.querySelector('#btn-scroll-right .icon');
        [leftIcon, rightIcon].forEach(icon => {
            if (!icon) return;
            icon.classList.remove('chevron-visible');
            icon.style.opacity = '';
        });
    }
    
    #postUpdateReadingProgressMessage = debounce(({
        fraction,
        cfi,
        reason
    }) => {
        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            fractionalCompletion: fraction,
            cfi: cfi,
            reason: reason,
            mainDocumentURL: mainDocumentURL,
        })
    }, 400)
    
    async #onRelocate({
        detail
    }) {
        const {
            fraction,
            location,
            tocItem,
            pageItem,
            cfi,
            reason
        } = detail
        const percent = percentFormat.format(fraction)
        const slider = $('#progress-slider')
        slider.style.visibility = 'visible'
        slider.value = fraction
        slider.style.setProperty('--value', slider.value); // keep slider progress updated
        // (removed: setting tocView currentHref here)
        const scrubbing = !!this.#progressScrubState;
        if (scrubbing) {
            detail.reason = 'live-scroll';
            detail.liveScrollPhase = 'dragging';
        } else if (detail.reason === 'live-scroll') {
            detail.liveScrollPhase = 'settled';
        }

        if (this.hasLoadedLastPosition) {
            this.#postUpdateReadingProgressMessage({
                fraction,
                cfi,
                reason
            })
        }
        
        await this.updateNavButtons();
        await this.navHUD?.handleRelocate(detail);
        const navLabel = this.navHUD?.getPrimaryDisplayLabel(detail);
        const tooltipParts = [];
        if (navLabel) {
            tooltipParts.push(navLabel);
        } else if (location?.current != null) {
            tooltipParts.push(`Loc ${location.current}`);
        }
        tooltipParts.push(percent);
        slider.title = tooltipParts.filter(Boolean).join(' · ');
        if (scrubbing && this.#progressScrubState?.pendingEnd) {
            this.#finalizeProgressScrubSession({ cancel: this.#progressScrubState.cancelRequested });
        }
        
        this.lastKnownFraction = fraction;
        const pct = Math.round(fraction * 100);
        this.lastPercentValue = pct;
        const percentInput = this.#jumpInput ?? document.getElementById('percent-jump-input');
        const percentButton = this.#jumpButton ?? document.getElementById('percent-jump-button');
        if (!this.#jumpInput && percentInput) this.#jumpInput = percentInput;
        if (!this.#jumpButton && percentButton) this.#jumpButton = percentButton;
        const pageEstimate = this.navHUD?.getPageEstimate(detail);
        if (pageEstimate) {
            this.lastPageEstimate = pageEstimate;
        }
        this.#updateJumpUnitAvailability();
        this.#syncJumpInputWithState();
        if (percentButton) {
            percentButton.disabled = true;
        }
    }
    
    async #goToDescriptor(descriptor) {
        if (!descriptor) return;
        if (descriptor.cfi) {
            await this.view.goTo(descriptor.cfi);
            return;
        }
        if (typeof descriptor.fraction === 'number') {
            await this.view.goToFraction(descriptor.fraction);
        }
    }
    
    async #onNavButtonClick(e) {
        const btn = e.currentTarget;
        const type = btn.dataset.buttonType;
        // For spinner placement
        const icon = btn.querySelector('svg');
        const label = btn.querySelector('.button-label');
        // Hide the label while loading
        if (label) label.style.visibility = 'hidden';
        // Replace SVG icon with spinner, respecting spinner placement
        if (icon) {
            btn._originalIcon = icon.cloneNode(true);
            const spinner = document.createElement('div');
            spinner.className = 'ispinner nav-spinner';
            spinner.innerHTML = '<div class="ispinner-blade"></div>'.repeat(8);
            
            // Improved spinner placement for RTL/LTR
            if (btn._spinnerAfterLabel) {
                if (icon) icon.remove();
                // Find the last visible .button-label
                const labels = btn.querySelectorAll('.button-label');
                let targetLabel = null;
                for (const lbl of labels) {
                    if (lbl.offsetParent !== null && getComputedStyle(lbl).display !== 'none') {
                        targetLabel = lbl;
                    }
                }
                if (targetLabel) {
                    targetLabel.after(spinner);
                } else {
                    btn.appendChild(spinner);
                }
            } else {
                // Default: replace icon with spinner
                icon.replaceWith(spinner);
            }
        }
        const restoreIcon = () => {
            const spinner = btn.querySelector('.ispinner.nav-spinner');
            if (spinner && btn._originalIcon) {
                spinner.replaceWith(btn._originalIcon);
                delete btn._originalIcon;
            }
            if (label) label.style.visibility = '';
        };
        let nav;
        switch (type) {
                // TODO: Clean up, the scroll cases here won't be reached because of above...
            case 'prev':
                postNavigationChromeVisibility(false, { source: 'button-prev', direction: 'backward' });
                // Go to previous section, then jump to its end
                nav = this.view.renderer.prevSection().then(() => {
                    // TODO: Add this here...
                    //this.view.fraction = 1;
                });
                break;
            case 'next':
                postNavigationChromeVisibility(true, { source: 'button-next', direction: 'forward' });
                nav = this.view.renderer.nextSection();
                break;
            case 'finish':
                window.webkit.messageHandlers.finishedReadingBook.postMessage({
                    topWindowURL: window.top.location.href,
                });
                nav = Promise.resolve();
                break;
            case 'restart':
                window.webkit.messageHandlers.startOver.postMessage({});
                await this.view.renderer.firstSection();
                nav = Promise.resolve();
                break;
        }
        Promise.resolve(nav).finally(() => {
            // Keep spinner for 'finish' or 'restart' – Swift layer will handle refresh
            if (type === 'finish' || type === 'restart') return;
            restoreIcon();
        });
    }
}

class CacheWarmer {
    constructor() {
        this.view
    }
    async open(file) {
        this.view = await getView(file, true)
        this.view.addEventListener('load', this.#onLoad.bind(this))
        
        const {
            book
        } = this.view
        this.view.renderer.setAttribute('flow', 'paginated')
        //        this.view.renderer.next()
        
        await this.view.renderer.firstSection()
    }
    
    async #onLoad({
        detail: {
            location
        }
    }) {
        window.webkit.messageHandlers.ebookCacheWarmerLoadedSection.postMessage({
            topWindowURL: window.top.location.href,
            frameURL: location,
        })
        
        if (!(await this.view.renderer.atEnd())) {
            window.webkit.messageHandlers.ebookCacheWarmerReadyToLoadNextSection.postMessage({
                topWindowURL: window.top.location.href,
            })
        } else {
            //            this.view.remove()
        }
    }
    
    //    #postUpdateReadingProgressMessage = debounce(({ fraction, cfi }) => {
    //        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
    //        window.webkit.messageHandlers.updateReadingProgress.postMessage({
    //        fractionalCompletion: fraction,
    //        cfi: cfi,
    //        mainDocumentURL: mainDocumentURL,
    //        })
    //    }, 400)
}

//const open = async file => {
//    document.body.removeChild($('#drop-target'))
//    const reader = new Reader()
//    globalThis.reader = reader
//    await reader.open(file)
//}

//const params = new URLSearchParams(location.search)
//const url = params.get('url')
//if (url) fetch(url)
//    .then(res => res.blob())
//    .then(blob => open(new File([blob], new URL(url).pathname)))
//    .catch(e => console.error(e))
//else dropTarget.style.visibility = 'visible'


const manabiEbookAudioBridge = {
    pausedForLoading: false,
    pendingNavigation: null,
    requestNavigation(payload) {
        if (!payload) { return; }
        const fraction = this.fractionForPayload(payload);
        if (!Number.isFinite(fraction)) { return; }
        if (this.pendingNavigation && Math.abs((this.pendingNavigation.fraction ?? fraction) - fraction) < 0.0001) {
            return;
        }
        this.pendingNavigation = Object.assign({}, payload, { fraction });
        this.pauseNativeAudio('section-navigation');
        globalThis.reader?.view?.goToFraction(fraction).catch(error => {
            console.error('ebook audio navigation failed', error);
            this.resumeNativeAudio('navigation-error');
        });
    },
    sectionReady(metadata) {
        if (metadata?.sectionURL) {
            this.pendingNavigation = null;
        }
        this.resumeNativeAudio('section-ready');
    },
    cancel(reason = 'cancelled') {
        this.pendingNavigation = null;
        if (this.pausedForLoading) {
            this.resumeNativeAudio(reason);
        }
    },
    fractionForPayload(payload) {
        if (Number.isFinite(payload?.fraction)) {
            return Math.max(0, Math.min(1, payload.fraction));
        }
        if (Number.isFinite(payload?.wordIndex) && Number.isFinite(payload?.totalWordCount) && payload.totalWordCount > 0) {
            return Math.max(0, Math.min(1, payload.wordIndex / payload.totalWordCount));
        }
        return null;
    },
    pauseNativeAudio(reason) {
        if (this.pausedForLoading) { return; }
        this.pausedForLoading = true;
        try {
            window.webkit?.messageHandlers?.ebookAudioLoadingState?.postMessage?.({ action: 'pause', reason, timestamp: Date.now() });
        } catch (_error) {
            // ignore
        }
    },
    resumeNativeAudio(reason) {
        if (!this.pausedForLoading) { return; }
        this.pausedForLoading = false;
        try {
            window.webkit?.messageHandlers?.ebookAudioLoadingState?.postMessage?.({ action: 'resume', reason, timestamp: Date.now() });
        } catch (_error) {
            // ignore
        }
    }
};
window.manabiEbookAudioBridge = manabiEbookAudioBridge;

window.cancelEbookAudioNavigation = (reason) => {
    window.manabiEbookAudioBridge?.cancel?.(reason || 'cancelled');
};

window.setEbookViewerLayout = (layoutMode) => {
    // TODO: Add scrolled mode back...
    //    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
}

window.setEbookViewerWritingDirection = (layoutMode) => {
    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
}

window.loadNextCacheWarmerSection = async () => {
    await window.cacheWarmer.view.renderer.nextSection()
}

window.loadEBook = ({
    url,
    layoutMode,
}) => {
    let reader = new Reader()
    globalThis.reader = reader
    if (pendingHideNavigationState !== null) {
        reader.setHideNavigationDueToScroll(pendingHideNavigationState);
        pendingHideNavigationState = null;
    }
    
    window.cacheWarmer = new CacheWarmer()
    
    if (url) fetch(url, {
        headers: {
            "IS-SWIFTUIWEBVIEW-VIEWER-FILE-REQUEST": "true",
        },
    })
        .then(res => res.blob())
        .then(async (blob) => {
            window.blob = blob
            if (layoutMode) {
                window.initialLayoutMode = layoutMode
            }
            await reader.open(new File([blob], new URL(url).pathname))
        })
        .then(async () => {
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({})
        })
        //.catch(e => console.error(e))
        }

window.loadLastPosition = async ({
    cfi,
    fractionalCompletion,
}) => {
    if (cfi.length > 0) {
        await globalThis.reader.view.goTo(cfi).catch(e => {
            console.error(e)
            if (fractionalCompletion) {
                globalThis.reader.view.goToFraction(fractionalCompletion)
            }
        })
    } else {
        await globalThis.reader.view.renderer.next()
    }
    globalThis.reader.hasLoadedLastPosition = true
    
    // Don't overlap cache warming with initial page load
    await window.cacheWarmer.open(new File([window.blob], new URL(globalThis.reader.view.ownerDocument.defaultView.top.location.href).pathname))
}

window.refreshBookReadingProgress = async (articleReadingProgress) => {
    globalThis.reader.markedAsFinished = !!articleReadingProgress.articleMarkedAsFinished;
    await globalThis.reader.updateNavButtons();
}

window.nextSection = async () => {
    const btn = globalThis.reader?.buttons?.next;
    if (btn && btn.offsetParent !== null && getComputedStyle(btn).visibility !== 'hidden') {
        btn.click();
    } else {
        await globalThis.reader?.view?.renderer?.nextSection?.();
    }
}

window.webkit.messageHandlers.ebookViewerInitialized.postMessage({})
