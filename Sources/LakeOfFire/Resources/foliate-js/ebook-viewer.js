import './view.js'
import { createTOCView } from './ui/tree.js'
import { createMenu } from './ui/menu.js'
import { Overlayer } from '../foliate-js/overlayer.js'

const replaceText = async (href, text, mediaType) => {
    return await fetch('ebook://ebook/process-text', {
    method: "POST", // *GET, POST, PUT, DELETE, etc.
    mode: "cors", // no-cors, *cors, same-origin
    cache: "no-cache", // *default, no-cache, reload, force-cache, only-if-cached
    headers: {
        "Content-Type": mediaType,
        "X-Replaced-Text-Location": href,
        "X-Content-Location": globalThis.reader.view.ownerDocument.defaultView.top.location.href,
    },
    body: text,
    }).then(async (response) => {
        if (!response.ok) {
            throw new Error(`HTTP error, status = ${response.status}`)
        }
        let html = await response.text();
        if (html && this.view.dataset.isCacheWarmer === 'true') {
            html = html.replace(/<body\s/i, "<body data-is-cache-warmer='true' ");
        }
        return html;
    }).catch(error => {
        console.error("Error replacing text:", error);
        throw error;
    });
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

const makeZipLoader = async file => {
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

const getView = async file => {
    let book
    if (!file.size) throw new Error('File not found')
    else if (await isZip(file)) {
        const loader = await makeZipLoader(file)
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
    document.body.append(view)
    await view.open(book)
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
    #tocView
    hasLoadedLastPosition = false
    style = {
        spacing: 1.4,
        justify: true,
        hyphenate: true,
    }
    annotations = new Map()
    annotationsByValue = new Map()
    closeSideBar() {
        $('#dimming-overlay').classList.remove('show')
        $('#side-bar').classList.remove('show')
    }
    constructor() {
        $('#side-bar-button').addEventListener('click', () => {
            $('#dimming-overlay').classList.add('show')
            $('#side-bar').classList.add('show')
        })
        $('#dimming-overlay').addEventListener('click', () => this.closeSideBar())

        const menu = createMenu([
            {
                name: 'layout',
                label: 'Layout',
                type: 'radio',
                items: [
                    ['Paginated', 'paginated'],
                    ['Scrolled', 'scrolled'],
                ],
                onclick: value => {
                    this.view?.renderer.setAttribute('flow', value)
                },
            },
        ])
        menu.element.classList.add('menu')

        $('#menu-button').append(menu.element)
        $('#menu-button > button').addEventListener('click', () =>
            menu.element.classList.toggle('show'))
        
        menu.groups.layout.select('paginated')
//        menu.groups.layout.select('scrolled')
    }
    async open(file) {
        this.hasLoadedLastPosition = false
        this.view = await getView(file)
        this.view.addEventListener('load', this.#onLoad.bind(this))
        this.view.addEventListener('relocate', this.#onRelocate.bind(this))

        const { book } = this.view
//        this.view.renderer.setAttribute('flow', 'scrolled')
        this.view.renderer.setAttribute('flow', 'paginated')
        this.view.renderer.setStyles?.(getCSS(this.style))
//        this.view.renderer.next()
        
        $('#header-bar').style.visibility = 'visible'
        $('#nav-bar').style.visibility = 'visible'
        $('#left-button').addEventListener('click', () => this.view.goLeft())
        $('#right-button').addEventListener('click', () => this.view.goRight())

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
            if (blob) {
                // From https://stackoverflow.com/a/52959897/89373
                (async () => {
                    const bmp = await createImageBitmap(blob);
                    const canvas = document.createElement('canvas');
                    let resizing = Math.min(1.0, (80.0 / bmp.width), (120.0 / bmp.height))
                    canvas.width = bmp.width * resizing;
                    canvas.height = bmp.height * resizing;
                    const ctx = canvas.getContext('bitmaprenderer');
                    ctx.transferFromImageBitmap(bmp);
                    let dataUrl = canvas.toDataURL("image/jpeg", 0.4);
                    
                    let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
                    window.webkit.messageHandlers.imageUpdated.postMessage({
                        newImageURL: dataUrl,
                        mainDocumentURL: mainDocumentURL,
                    })
                })().catch(console.error);
            }
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
    #handleKeydown(event) {
        const k = event.key
        if (k === 'ArrowLeft' || k === 'h') this.view.goLeft()
        else if(k === 'ArrowRight' || k === 'l') this.view.goRight()
    }
    #onLoad({ detail: { doc } }) {
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
            if (prevButton.nextElementSibling === nextButton) {
                container.insertBefore(nextButton, prevButton);
            }
        } else {
            if (nextButton.nextElementSibling === prevButton) {
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
        const slider = $('#progress-slider')
        slider.style.visibility = 'visible'
        slider.value = fraction
        slider.title = `${percent} · ${loc}`
        if (tocItem?.href) this.#tocView?.setCurrentHref?.(tocItem.href)
        
        if (this.hasLoadedLastPosition) {
            this.#postUpdateReadingProgressMessage({ fraction, cfi })
        }
    }
}

class CacheWarmer {
    constructor() {
        this.view
    }
    async open(file) {
        this.view = await getView(file)
        this.view.style.display = 'none'
//        this.view.dataset.isCacheWarmer = 'true'
        this.view.addEventListener('load', this.#onLoad.bind(this))
        
        const { book } = this.view
//        this.view.renderer.setAttribute('flow', 'scrolled')
        this.view.renderer.setAttribute('flow', 'paginated')
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
            this.view.remove()
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

window.loadNextCacheWarmerSection = async () => {
    await window.cacheWarmer.view.renderer.nextSection()
}

window.loadEBook = ({ url }) => {
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
            await reader.open(new File([blob], new URL(url).pathname))
        })
        .then(() => {
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({})
        })
        .catch(e => console.error(e))
}

window.loadLastPosition = async ({ cfi }) => {
    if (cfi.length > 0) {
        await globalThis.reader.view.goTo(cfi).catch(e => console.error(e))
    } else {
        await globalThis.reader.view.renderer.next()
    }
    globalThis.reader.hasLoadedLastPosition = true
    
    // Don't overlap cache warming with initial page load
    await cacheWarmer.open(new File([window.blob], new URL(globalThis.reader.view.ownerDocument.defaultView.top.location.href).pathname))
}

window.webkit.messageHandlers.ebookViewerInitialized.postMessage({})
