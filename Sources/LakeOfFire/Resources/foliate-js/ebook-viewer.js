import './view.js'
import { createTOCView } from './ui/tree.js'
import { Overlayer } from '../foliate-js/overlayer.js'

// Factory for replaceText with isCacheWarmer support
const makeReplaceText = (isCacheWarmer) => async (href, text, mediaType) => {
    const response = await fetch('ebook://ebook/process-text', {
        method: "POST",
        mode: "cors",
        cache: "no-cache",
        headers: {
            "Content-Type": mediaType,
            "X-Replaced-Text-Location": href,
            "X-Content-Location": globalThis.reader.view.ownerDocument.defaultView.top.location.href,
        },
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

const debounce = (f, wait, immediate) => {
    let timeout
    return (...args) => {
        const later = () => {
            timeout = null
            if (!immediate) f(...args)
                }
        const callNow = immediate && !timeout
        if (timeout) clearTimeout(timeout)
            timeout = setTimeout(later, wait)
            if (callNow) f(...args)
                }
}

const isZip = async file => {
    const arr = new Uint8Array(await file.slice(0, 4).arrayBuffer())
    return arr[0] === 0x50 && arr[1] === 0x4b && arr[2] === 0x03 && arr[3] === 0x04
}

const makeZipLoader = async (file, isCacheWarmer) => {
    const { configure, ZipReader, BlobReader, TextWriter, BlobWriter } =
    await import('./vendor/zip.js')
    configure({ useWebWorkers: false })
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
    return { entries, loadText, loadBlob, getSize, replaceText }
}

const getFileEntries = async entry => entry.isFile ? entry
: (await Promise.all(Array.from(
                                await new Promise((resolve, reject) => entry.createReader()
                                                  .readEntries(entries => resolve(entries), error => reject(error))),
                                getFileEntries))).flat()

const isCBZ = ({ name, type }) =>
type === 'application/vnd.comicbook+zip' || name.endsWith('.cbz')

const isFB2 = ({ name, type }) =>
type === 'application/x-fictionbook+xml' || name.endsWith('.fb2')

const isFBZ = ({ name, type }) =>
type === 'application/x-zip-compressed-fb2'
|| name.endsWith('.fb2.zip') || name.endsWith('.fbz')

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
                const { EPUB } = await import('./epub.js')
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
    document.body.append(view)
    //}
    if (isCacheWarmer) {
        view.style.display = 'none'
    }
    await view.open(book, isCacheWarmer)
    return view
}

const getCSS = ({ spacing, justify, hyphenate }) => `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: light dark;
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
`

const $ = document.querySelector.bind(document)

const locales = 'en'
const percentFormat = new Intl.NumberFormat(locales, { style: 'percent' })

class Reader {
    #show(btn, show = true) {
        if (show) {
            btn.hidden = false;
            btn.style.visibility = 'visible';
        } else {
            btn.hidden = true;
            btn.style.visibility = 'hidden';
        }
    }
    #tocView
    hasLoadedLastPosition = false
    markedAsFinished = false;
    lastPercentValue = null;
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
    }
    closeSideBar() {
        $('#dimming-overlay').classList.remove('show')
        $('#side-bar').classList.remove('show')
    }
    constructor() {
        $('#progress-button').addEventListener('click', () => {
            this.openSideBar()
        })
        $('#side-bar-close-button').addEventListener('click', () => {
            this.closeSideBar()
        })
        $('#dimming-overlay').addEventListener('click', () => this.closeSideBar())
    }
    async open(file) {
        $('#loading-indicator').style.display = 'block'
        
        // Show loading spinners in left/right stack and hide other nav buttons
        document.getElementById('btn-left-loading').hidden = false;
        document.getElementById('btn-right-loading').hidden = false;
        
        this.hasLoadedLastPosition = false
        this.view = await getView(file, false)
        this.view.renderer.setAttribute('animated', true)
        if (typeof window.initialLayoutMode !== 'undefined') {
            this.view.renderer.setAttribute('flow', window.initialLayoutMode)
        }
        this.view.addEventListener('goTo', this.#onGoTo.bind(this))
        this.view.addEventListener('load', this.#onLoad.bind(this))
        this.view.addEventListener('relocate', this.#onRelocate.bind(this))
        
        const { book } = this.view
        this.bookDir = book.dir || 'ltr';
        this.isRTL   = this.bookDir === 'rtl';
        this.view.renderer.setStyles?.(getCSS(this.style))
        //        this.view.renderer.next()
        
        $('#nav-bar').style.visibility = 'visible'
        this.buttons = {
            leftScroll:  document.getElementById('btn-left-scroll'),
            prev:        document.getElementById('btn-prev-chapter'),
            rightScroll: document.getElementById('btn-right-scroll'),
            next:        document.getElementById('btn-next-chapter'),
            finish:      document.getElementById('btn-finish'),
            restart:     document.getElementById('btn-restart'),
        };
        // Hide all other nav buttons except spinners
        for (const btn of Object.values(this.buttons)) {
            if (btn && btn.id !== 'btn-left-loading' && btn.id !== 'btn-right-loading') {
                btn.hidden = true;
            }
        }
        
        // Flip chevron icons for RTL books
        if (this.isRTL) {
            const flipChevron = (btn, leftArrow) => {
                const path = btn.querySelector('path');
                if (path) {
                    path.setAttribute('d', leftArrow
                                      ? 'M 15 6 L 9 12 L 15 18'  // left chevron (◀)
                                      : 'M 9 6 L 15 12 L 9 18'); // right chevron (▶)
                }
            };
            
            flipChevron(this.buttons.prev, false);        // ▶
            flipChevron(this.buttons.next, true);         // ◀
            flipChevron(this.buttons.leftScroll, false);  // ▶
            flipChevron(this.buttons.rightScroll, true);  // ◀
            
            // Swap label/icon order for chapter buttons in RTL
            // Ensure "Next Chapter" shows "< Next Chapter"
            const nextBtn = this.buttons.next;
            const nextLabel = nextBtn.querySelector('.button-label');
            const nextIcon  = nextBtn.querySelector('svg');
            if (nextIcon && nextLabel && nextIcon !== nextLabel.previousSibling) {
                nextBtn.insertBefore(nextIcon, nextLabel);
            }
            
            // Ensure "Previous Chapter" shows "Previous Chapter >"
            const prevBtn = this.buttons.prev;
            const prevLabel = prevBtn.querySelector('.button-label');
            const prevIcon  = prevBtn.querySelector('svg');
            if (prevIcon && prevLabel && prevLabel !== prevIcon.previousSibling) {
                prevBtn.insertBefore(prevLabel, prevIcon);
            }
        }
        Object.values(this.buttons).forEach(btn =>
                                            btn.addEventListener('click', this.#onNavButtonClick.bind(this))
                                            );
        
        // Reorder toolbar children for RTL/LTR so left/right stacks and progress are positioned correctly
        const navBar = document.getElementById('nav-bar');
        const leftStack = document.getElementById('left-stack');
        const rightStack = document.getElementById('right-stack');
        const progressWrapper = document.getElementById('progress-wrapper');
        navBar.innerHTML = '';
        if (this.isRTL) {
            navBar.append(rightStack, progressWrapper, leftStack);
        } else {
            navBar.append(leftStack, progressWrapper, rightStack);
        }
        
        const slider = $('#progress-slider')
        slider.dir = book.dir
        slider.addEventListener('input', e =>
                                this.view.goToFraction(parseFloat(e.target.value)))
        const sizes = book.sections.filter(s => s.linear !== 'no').map(s => s.size)
        if (sizes.length < 100) {
            const total = sizes.reduce((a, b) => a + b, 0)
            let sum = 0
            for (const size of sizes.slice(0, -1)) {
                sum += size
                const option = document.createElement('option')
                option.value = sum / total
                $('#tick-marks').append(option)
            }
        }
        
        // Percent jump input/button wiring
        const percentInput = document.getElementById('percent-jump-input');
        const percentButton = document.getElementById('percent-jump-button');
        
        percentInput.addEventListener('input', () => {
            const value = parseFloat(percentInput.value);
            const valid = !isNaN(value) && value >= 0 && value <= 100 && value !== this.lastPercentValue;
            percentButton.disabled = !valid;
        });
        
        percentButton.addEventListener('click', () => {
            const value = parseFloat(percentInput.value);
            if (!isNaN(value) && value >= 0 && value <= 100) {
                this.lastPercentValue = value;
                percentButton.disabled = true;
                this.view.goToFraction(value / 100);
            }
        });
        
        document.addEventListener('keydown', this.#handleKeydown.bind(this))
        
        const title = book.metadata?.title ?? 'Untitled Book'
        document.title = title
        $('#side-bar-title').innerText = title
        const author = book.metadata?.author
        let authorText = typeof author === 'string' ? author
        : author
        ?.map(author => typeof author === 'string' ? author : author.name)
        ?.join(', ')
        ?? ''
        $('#side-bar-author').innerText = authorText
        window.webkit.messageHandlers.pageMetadataUpdated.postMessage({
            'title': title, 'author': authorText, 'url': window.top.location.href})
        
        Promise.resolve(book.getCover?.())?.then(blob => {
            blob ? $('#side-bar-cover').src = URL.createObjectURL(blob) : null
        })
        
        const toc = book.toc
        if (toc) {
            this.#tocView = createTOCView(toc, href => {
                this.view.goTo(href).catch(e => console.error(e))
                this.closeSideBar()
            })
            $('#toc-view').append(this.#tocView.element)
        }
        
        // load and show highlights embedded in the file by Calibre
        const bookmarks = await book.getCalibreBookmarks?.()
        if (bookmarks) {
            const { fromCalibreHighlight } = await import('./epubcfi.js')
            for (const obj of bookmarks) {
                if (obj.type === 'highlight') {
                    const value = fromCalibreHighlight(obj)
                    const color = obj.style.which
                    const note = obj.notes
                    const annotation = { value, color, note }
                    const list = this.annotations.get(obj.spine_index)
                    if (list) list.push(annotation)
                        else this.annotations.set(obj.spine_index, [annotation])
                            this.annotationsByValue.set(value, annotation)
                            }
            }
            this.view.addEventListener('create-overlay', e => {
                const { index } = e.detail
                const list = this.annotations.get(index)
                if (list) for (const annotation of list)
                    this.view.addAnnotation(annotation)
                    })
            this.view.addEventListener('draw-annotation', e => {
                const { draw, annotation } = e.detail
                const { color } = annotation
                draw(Overlayer.highlight, { color })
            })
            this.view.addEventListener('show-annotation', e => {
                const annotation = this.annotationsByValue.get(e.detail.value)
                if (annotation.note) alert(annotation.note)
                    })
        }
    }
    
    updateNavButtons() {
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
        // Hide the loading spinners now that navigation buttons are ready
        const leftLoading = document.getElementById('btn-left-loading');
        const rightLoading = document.getElementById('btn-right-loading');
        if (leftLoading) leftLoading.hidden = true;
        if (rightLoading) rightLoading.hidden = true;
        if (!this.view?.renderer) return;
        const r = this.view.renderer;
        const atStart = r.start <= 1;
        const atEnd = r.viewSize - r.end <= 1;
        let hasPrev = false, hasNext = false;
        if (typeof r.getContents === 'function' && r.sections) {
            const currentIndex = r.getContents()?.[0]?.index ?? 0;
            const sections = r.sections;
            hasPrev = sections.slice(0, currentIndex).some(s => s.linear !== 'no');
            hasNext = sections.slice(currentIndex + 1).some(s => s.linear !== 'no');
        }
        // Update left stack: only show one, or hide both if neither needed
        if (atStart && hasPrev) {
            this.#show(this.buttons.prev, true);
            this.#show(this.buttons.leftScroll, false);
        } else if (!atStart) {
            this.#show(this.buttons.prev, false);
            this.#show(this.buttons.leftScroll, true);
        } else {
            this.#show(this.buttons.prev, false);
            this.#show(this.buttons.leftScroll, false);
        }
        if (atEnd) {
            if (hasNext) {
                this.#show(this.buttons.next, true);
                this.#show(this.buttons.finish, false);
                this.#show(this.buttons.restart, false);
                this.#show(this.buttons.rightScroll, false);
            } else {
                this.#show(this.buttons.next, false);
                this.#show(this.buttons.rightScroll, false);
                if (this.markedAsFinished) {
                    this.#show(this.buttons.restart, true);
                    this.#show(this.buttons.finish, false);
                } else {
                    this.#show(this.buttons.finish, true);
                    this.#show(this.buttons.restart, false);
                }
            }
        } else {
            this.#show(this.buttons.next, false);
            this.#show(this.buttons.finish, false);
            this.#show(this.buttons.restart, false);
            this.#show(this.buttons.rightScroll, true);
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
    }
    #handleKeydown(event) {
        const k = event.key
        if (k === 'ArrowLeft' || k === 'h') this.view.goLeft()
            else if(k === 'ArrowRight' || k === 'l') this.view.goRight()
                }
    #onGoTo({}) {
        $('#loading-indicator').style.display = 'block'
    }
    #onLoad({ detail: { doc } }) {
        $('#loading-indicator').style.display = 'none'
        
        doc.addEventListener('keydown', this.#handleKeydown.bind(this))
        window.webkit.messageHandlers.updateCurrentContentPage.postMessage({
            topWindowURL: window.top.location.href,
            currentPageURL: doc.location.href,
        })
        
        // TODO: Should also offer "end" if last non-glossary/backmatter section
        if (this.view.renderer.atEnd) {
            doc.getElementById('manabi-finished-reading-book-container')?.classList.remove('manabi-hidden')
        } else {
            doc.getElementById('manabi-next-chapter-button')?.classList.remove('manabi-hidden')
        }
        if (!this.view.renderer.atStart) {
            doc.getElementById('manabi-previous-chapter-button')?.classList.remove('manabi-hidden')
        }
        
        // Add event listeners for the previous and next buttons
        doc.getElementById('manabi-previous-chapter-button')?.addEventListener('click', function () {
            this.view.renderer.prevSection()
        }.bind(this))
        doc.getElementById('manabi-next-chapter-button')?.addEventListener('click', function () {
            this.view.renderer.nextSection()
        }.bind(this))
        
        // Reorder buttons based on the writing mode and direction
        const container = doc.getElementById('manabi-chapter-navigation-buttons-container');
        const prevButton = doc.getElementById('manabi-previous-chapter-button');
        const nextButton = doc.getElementById('manabi-next-chapter-button');
        const bookDir = this.view.renderer.bookDir;
        if (bookDir === 'rtl') {
            if (prevButton && prevButton.nextElementSibling === nextButton) {
                container.insertBefore(nextButton, prevButton);
            }
        } else {
            if (nextButton && nextButton.nextElementSibling === prevButton) {
                container.insertBefore(prevButton, nextButton);
            }
        }
    }
    
    #postUpdateReadingProgressMessage = debounce(({ fraction, cfi }) => {
        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            fractionalCompletion: fraction,
            cfi: cfi,
            mainDocumentURL: mainDocumentURL,
        })
    }, 400)
    
    #onRelocate({ detail }) {
        const { fraction, location, tocItem, pageItem, cfi } = detail
        const percent = percentFormat.format(fraction)
        const loc = pageItem ? `Page ${pageItem.label}` : `Loc ${location.current}`
        const progressButton = $('#progress-button')
        progressButton.textContent = percent
        progressButton.style.visibility = 'visible'
        const slider = $('#progress-slider')
        slider.style.visibility = 'visible'
        slider.value = fraction
        slider.title = `${percent} · ${loc}`
        if (tocItem?.href) this.#tocView?.setCurrentHref?.(tocItem.href)
            
            if (this.hasLoadedLastPosition) {
                this.#postUpdateReadingProgressMessage({ fraction, cfi })
            }
        this.updateNavButtons();
        // Keep percent-jump input in sync with scroll
        const percentInput = document.getElementById('percent-jump-input');
        const percentButton = document.getElementById('percent-jump-button');
        if (percentInput && percentButton) {
            const pct = Math.round(fraction * 100);
            percentInput.value = pct;
            this.lastPercentValue = pct;
            percentButton.disabled = true;
        }
    }
    
    #onNavButtonClick(e) {
        const btn = e.currentTarget;
        const type = btn.dataset.buttonType;
        const icon = btn.querySelector('svg');
        const label = btn.querySelector('.button-label');
        // Only show spinner for prev/next/finish/restart chapter nav
        if (
            type !== 'prev' &&
            type !== 'next' &&
            type !== 'finish' &&
            type !== 'restart'
            ) {
                switch (type) {
                    case 'scroll-prev':
                        // In RTL view, left arrow should scroll forward
                        this.isRTL ? this.view.goRight() : this.view.goLeft();
                        break;
                    case 'scroll-next':
                        // In RTL view, right arrow should scroll backward
                        this.isRTL ? this.view.goLeft() : this.view.goRight();
                        break;
                }
                return;
            }
        // Hide the label while loading
        if (label) label.style.visibility = 'hidden';
        // Replace SVG icon with spinner
        if (icon) {
            btn._originalIcon = icon.cloneNode(true);
            const spinner = document.createElement('div');
            spinner.className = 'ispinner nav-spinner';
            spinner.innerHTML = '<div class="ispinner-blade"></div>'.repeat(8);
            icon.replaceWith(spinner);
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
            case 'scroll-prev':
                // In RTL view, left arrow should scroll forward
                nav = this.isRTL ? this.view.goRight() : this.view.goLeft();
                break;
            case 'scroll-next':
                // In RTL view, right arrow should scroll backward
                nav = this.isRTL ? this.view.goLeft() : this.view.goRight();
                break;
            case 'prev':
                nav = this.view.renderer.prevSection();
                break;
            case 'next':
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
                this.view.renderer.firstSection();
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
        
        const { book } = this.view
        this.view.renderer.setAttribute('flow', 'scrolled')
        //        this.view.renderer.next()
        
        await this.view.renderer.firstSection()
    }
    
    #onLoad({ detail: { doc } }) {
        //        window.webkit.messageHandlers.pritn.postMessage({"test": "cache onload..", "1": this.view.ownerDocument.defaultView})
        window.webkit.messageHandlers.ebookCacheWarmerLoadedSection.postMessage({
            topWindowURL: window.top.location.href,
            frameURL: event.detail.doc.location.href,
        })
        
        if (!this.view.renderer.atEnd) {
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


window.setEbookViewerLayout = (layoutMode) => {
    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
}

window.setEbookViewerWritingDirection = (layoutMode) => {
    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
}

window.loadNextCacheWarmerSection = async () => {
    await window.cacheWarmer.view.renderer.nextSection()
}

window.loadEBook = ({ url, layoutMode }) => {
    let reader = new Reader()
    globalThis.reader = reader
    
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
        .then(() => {
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({})
        })
        .catch(e => console.error(e))
        }

window.loadLastPosition = async ({ cfi }) => {
    //console.log("load last pos")
    //console.log(cfi)
    if (cfi.length > 0) {
        await globalThis.reader.view.goTo(cfi).catch(e => console.error(e))
    } else {
        await globalThis.reader.view.renderer.next()
    }
    globalThis.reader.hasLoadedLastPosition = true
    
    // Don't overlap cache warming with initial page load
    await window.cacheWarmer.open(new File([window.blob], new URL(globalThis.reader.view.ownerDocument.defaultView.top.location.href).pathname))
}

window.refreshBookReadingProgress = function (articleReadingProgress) {
    globalThis.reader.markedAsFinished = !!articleReadingProgress.articleMarkedAsFinished;
    globalThis.reader.updateNavButtons();
}

window.webkit.messageHandlers.ebookViewerInitialized.postMessage({})
