"""Real ebook-viewer shell with generated EPUB and explicitly simulated native persistence.
No loading gate, CSP or renderer geometry is disabled to make this test pass.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from html import escape
from urllib.parse import quote
from pathlib import Path
from threading import Thread
import json
import os
import re
import sys
import unittest
import zipfile
from playwright.sync_api import sync_playwright
from browser_wait import wait_for_reader
from prepared_book_fixture import prepared_chapter
ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'Sources/LakeOfFireReader/Resources/Resources/foliate-js'

def make_epub(chapter_factory=prepared_chapter, *, missing_spine_entry=False):
    output = BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip')
        archive.writestr('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''')
        opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">book-actions-test</dc:identifier><dc:title>Book Actions Test</dc:title><dc:language>ja</dc:language><meta property="dcterms:modified">2026-09-19T00:00:00Z</meta></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>'''
        if missing_spine_entry:
            opf = opf.replace('<spine>', '<spine><itemref idref="missing"/>')
        archive.writestr('OPS/book.opf', opf)
        archive.writestr('OPS/nav.xhtml', '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">First Chapter</a></li><li><a href="two.xhtml">Last Chapter</a></li></ol></nav></body></html>''')
        for name in ['one', 'two']:
            archive.writestr('OPS/' + name + '.xhtml', chapter_factory(name))
    return output.getvalue()

def make_uri_epub(with_toc=True):
    directory = 'OPS/100%/draft#?'
    names = ['100%.xhtml', 'literal%20.xhtml', ' trailing.xhtml ', 'literal .xhtml',
             'chapter#draft.xhtml', 'chapter?draft.xhtml', 'literal%2F.xhtml', '日本語.xhtml', 'A.xhtml']
    output = BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip')
        archive.writestr('META-INF/container.xml',
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
            f'<rootfile full-path="{escape(directory, quote=True)}/book.opf" media-type="application/oebps-package+xml"/>'
            '</rootfiles></container>')
        manifest = ''.join(f'<item id="c{i}" href="{quote(name, safe="")}" media-type="application/xhtml+xml"/>'
                           for i, name in enumerate(names))
        if with_toc:
            manifest += '<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>'
        spine = ''.join(f'<itemref idref="c{i}"/>' for i in range(len(names)))
        archive.writestr(directory + '/book.opf',
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">uri-book</dc:identifier>'
            '<dc:title>URI References</dc:title><dc:language>tr</dc:language></metadata>'
            f'<manifest>{manifest}</manifest><spine>{spine}</spine></package>')
        def navigation_ref(name):
            encoded = '%41.xhtml' if name == 'A.xhtml' else quote(name, safe='')
            return re.sub(r'%[0-9A-Fa-f]{2}', lambda value: value[0].lower(), encoded)
        nav = ''.join(f'<li><a href="{navigation_ref(name)}#uri-fragment">Chapter {i}</a></li>'
                      for i, name in enumerate(names))
        archive.writestr(directory + '/nav.xhtml',
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            f'<body><nav epub:type="toc"><ol>{nav}</ol></nav></body></html>')
        for i, name in enumerate(names):
            next_href = quote(names[(i + 1) % len(names)], safe='') + '#uri-fragment'
            content = prepared_chapter(f'chapter-{i}').replace('</body>',
                f'<p id="uri-fragment">target</p><p id="uri-language">I zzz</p>'
                f'<a id="uri-next" href="{next_href}">next</a></body>')
            archive.writestr(directory + '/' + name, content)
    return output.getvalue(), directory, names


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
    def translate_path(self, path):
        prefix = '/load/viewer-assets/foliate-js/'
        clean = path.split('?', 1)[0]
        if clean.startswith(prefix):
            relative = Path(clean[len(prefix):])
            if '..' not in relative.parts: return str(ASSETS / relative)
        return super().translate_path(path)
    def do_GET(self):
        fixture = getattr(self.server, 'epub_fixtures', {}).get(self.path)
        if self.path == '/fixture.epub' or fixture is not None:
            data = fixture if fixture is not None else make_epub(); self.send_response(200)
            self.send_header('Content-Type', 'application/epub+zip')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        super().do_GET()

BRIDGE = '''(() => {
    window.manabi_compactSegmentSidecarSchemaVersion = 14;
    window.nativeMessages = []; window.bookActionRequests = [];
    window.accountPresentation = '1:1';
    window.persistedProgress = {readSegmentIdentifiers:['previously-read-segment'],sentenceIdentifiersRead:['previously-read-sentence'],articleMarkedAsFinished:false};
    window.historicalReadIDs = ['previously-read-segment'];
    window.bookEpoch = 'initial'; window.chapterEpochs = {}; window.stateSequence = 0;
    let lastLocation = null;
    const handlers = {};
    for (const name of ['ebookViewerInitialized','ebookViewerLoaded','pageMetadataUpdated','updateReadingProgress','ebookNativeMarkReadState','markAllSectionsAsRead','finishedReadingBook','startOver','ebookNavigationVisibility','readerOnError']) {
        handlers[name] = {postMessage(payload) { nativeMessages.push({name,payload}); }};
    }
    handlers.markSectionAsRead = {postMessage(payload) {
        nativeMessages.push({name:'markSectionAsRead',payload});
        queueMicrotask(() => reader?.nativeMarkReadRequestCoordinator?.settle({
            requestID:payload.requestID,sectionId:payload.sectionId,
            manualReadPendingProtocol:1,
            manualReadPendingObservationToken:payload.manualReadPendingObservationToken,
            manualReadPendingState:'finished',
            success:false,errorCode:'simulatedReadRefusal'
        }));
    }};
    window.publishState = (request, nativeRefresh=false) => {
        lastLocation = request; window.lastNativeBookStateRequest = request;
        const key = 'a'.repeat(64);
        const scope = request.isEndPage ? null : {articleProgressID:'book',articleEpochID:bookEpoch,chapterKey:key,chapterEpochID:chapterEpochs[key] ?? null};
        const index = reader.view.renderer.displayedIndex;
        const sectionLocation = reader.view.book.sections[index]?.id;
        const state = {revision:++stateSequence,articleProgressID:'book',articleEpochID:bookEpoch,scope,finished:persistedProgress.articleMarkedAsFinished,
            bookReadPresence:persistedProgress.readSegmentIdentifiers.length?'present':'empty',chapterReadPresence:request.isEndPage?'empty':persistedProgress.readSegmentIdentifiers.length?'present':'empty',
            readSegmentIdentifiers:request.isEndPage?[]:persistedProgress.readSegmentIdentifiers,sentenceIdentifiersRead:request.isEndPage?[]:persistedProgress.sentenceIdentifiersRead};
        const context = {contextID:bookEpoch+'-'+(scope?.chapterEpochID??'0')+'-'+(request.isEndPage?'end':sectionLocation),articleProgressID:'book',articleEpochID:bookEpoch,scope,sectionLocation:request.isEndPage?null:sectionLocation,isEndPage:request.isEndPage};
        window.manabi_bookReadingStateDidUpdate(request.requestID,{ok:true,accountPresentation,state,context,nativeRefresh,location:{sectionURL:request.sectionURL,isEndPage:request.isEndPage,locationRevision:request.locationRevision}});
    };
    handlers.ebookBookReadingState = {postMessage(payload) { queueMicrotask(()=>publishState(payload)); }};
    handlers.ebookBookAction = {postMessage(payload) { bookActionRequests.push(payload); }};
    window.webkit = {messageHandlers:handlers};
    window.replyToBookAction = async(request,ok) => {
        let navigation;
        if(ok) {
            if(request.action==='finishBook') persistedProgress.articleMarkedAsFinished=true;
            else {
                if(request.action==='startBookOver') { bookEpoch=request.requestID;persistedProgress.articleMarkedAsFinished=false; }
                else chapterEpochs[request.context.scope.chapterKey]=request.requestID;
                persistedProgress.readSegmentIdentifiers=[];persistedProgress.sentenceIdentifiersRead=[];
            }
            publishState(lastLocation,true);
            if(request.action!=='finishBook') navigation=await reader.navigateBookReadingAction({
                action:request.action,accountPresentation,articleProgressID:'book',articleEpochID:bookEpoch,chapterEpochID:request.action==='startChapterOver'?request.requestID:null,
                sectionLocation:request.context.sectionLocation,locationRevision:request.context.locationRevision});
        }
        window.manabi_bookActionDidComplete(request.deliveryID,{requestID:request.requestID,accountPresentation,ok,committed:ok,
            finished:persistedProgress.articleMarkedAsFinished,navigation,...(ok?{}:{error:'Simulated native write failure'})});
    };
})();'''

class ViewerAssetServer(ThreadingHTTPServer):
    # A browser discovers the complete ES module graph concurrently. The
    # default five-connection backlog can reset those requests before our
    # loopback server accepts them, leaving the viewer script uninitialized.
    request_queue_size = 128


class BookEndcapShellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ViewerAssetServer(('127.0.0.1', 0), partial(Handler, directory=str(ROOT)))
        cls.addClassCleanup(cls.server.server_close)
        Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.addClassCleanup(cls.server.shutdown)
        cls.pw = sync_playwright().start()
        cls.addClassCleanup(cls.pw.stop)
        launch_args = ['--disable-features=MacAppCodeSignClone'] if sys.platform == 'darwin' else []
        cls.browser = cls.pw.chromium.launch(
            executable_path=os.environ.get('CHROMIUM_PATH'), headless=True,
            args=launch_args)
        # unittest runs class cleanups even if setup or an earlier cleanup fails.
        # Reverse registration closes the browser before its Playwright runtime.
        cls.addClassCleanup(cls.browser.close)

    def test_svg2_resource_hrefs_load_archive_bytes_and_preserve_navigation(self):
        page = self.browser.new_page(viewport={'width': 390, 'height': 844})
        self.addCleanup(page.close)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        result = page.evaluate('''async () => {
            const {Loader} = await import('./epub.js')
            const svgNS = 'http://www.w3.org/2000/svg'
            const xlinkNS = 'http://www.w3.org/1999/xlink'
            const pixel = `<svg xmlns="${svgNS}" width="3" height="2"><rect width="3" height="2" fill="red"/></svg>`
            const symbols = `<svg xmlns="${svgNS}"><rect id="shape" width="3" height="2"/></svg>`
            const chapter = `<svg xmlns="${svgNS}" xmlns:xlink="${xlinkNS}" viewBox="0 0 100 100">
                <defs><rect id="local-shape" width="1" height="1"/></defs>
                <image id="modern" href="../images/pixel.svg"/>
                <image id="precedence" href="../images/pixel.svg" xlink:href="../images/missing.svg"/>
                <image id="legacy" xlink:href="../images/pixel.svg"/>
                <use id="remote-symbol" href="../images/symbols.svg#shape"/>
                <filter><feImage id="filter-image" href="../images/pixel.svg"/></filter>
                <use id="local-symbol" href="#local-shape"/>
                <image id="external" href="https://example.invalid/image.svg"/>
                <a id="navigation" href="../two.xhtml#there"><text>Next</text></a>
            </svg>`
            const texts = {'OPS/chapters/one.svg':chapter, 'OPS/images/pixel.svg':pixel,
                'OPS/images/symbols.svg':symbols}
            const manifest = Object.keys(texts).map(href => ({href,mediaType:'image/svg+xml'}))
            const loader = new Loader({resources:{manifest},loadText:async href=>texts[href],
                loadBlob:async href=>new Blob([texts[href]],{type:'image/svg+xml'})})
            try {
                const url = await loader.loadItem(manifest[0])
                const doc = new DOMParser().parseFromString(await (await fetch(url)).text(), 'image/svg+xml')
                const href = id => doc.getElementById(id).getAttribute('href')
                const modern = href('modern')
                const resourceIsBlob = modern.startsWith('blob:')
                let loadedBytes = null, decodedSize = null
                if (resourceIsBlob) {
                    loadedBytes = await (await fetch(modern)).text()
                    const image = new Image()
                    image.src = modern
                    await image.decode()
                    decodedSize = [image.naturalWidth,image.naturalHeight]
                }
                const remoteSymbol = href('remote-symbol')
                return {resourceIsBlob,loadedBytes,pixel,decodedSize,
                    sameResource:href('precedence')===modern && href('filter-image')===modern,
                    legacy:doc.getElementById('legacy').getAttributeNS(xlinkNS,'href')===modern,
                    symbolIsBlob:remoteSymbol.startsWith('blob:'),symbolFragment:remoteSymbol.split('#')[1],
                    symbolBytes:remoteSymbol.startsWith('blob:')
                        ? await (await fetch(remoteSymbol)).text() : null,
                    local:href('local-symbol'),external:href('external'),navigation:href('navigation'),
                    ignoredFallback:doc.getElementById('precedence').getAttributeNS(xlinkNS,'href')}
            } finally { loader.destroy() }
        }''')
        self.assertTrue(result['resourceIsBlob'])
        self.assertEqual(result['loadedBytes'], result['pixel'])
        self.assertEqual(result['decodedSize'], [3, 2])
        self.assertTrue(result['sameResource'])
        self.assertTrue(result['legacy'])
        self.assertTrue(result['symbolIsBlob'])
        self.assertEqual(result['symbolFragment'], 'shape')
        self.assertIn('id="shape"', result['symbolBytes'])
        self.assertEqual(result['local'], '#local-shape')
        self.assertEqual(result['external'], 'https://example.invalid/image.svg')
        self.assertEqual(result['navigation'], '../two.xhtml#there')
        self.assertEqual(result['ignoredFallback'], '../images/missing.svg')

    def test_epub_inline_css_comment_separated_declarations(self):
        # Real browser DOM traversal, serialization and CSS application through
        # shipping Loader callers; this Chromium case is not WebKit evidence.
        page = self.browser.new_page(viewport={'width': 800, 'height': 600})
        self.addCleanup(page.close)
        page.route('**/epub-inline-css', lambda route: route.fulfill(
            status=200, content_type='text/html', body='<!doctype html><title>CSS fixture</title>'))
        page.goto(f'http://127.0.0.1:{self.server.server_port}/epub-inline-css')
        result = page.evaluate(r"""async () => {
            const { Loader } = await import('/load/viewer-assets/foliate-js/epub.js')
            const check = (condition, message) => { if (!condition) throw new Error(message) }
            const baseSheet = `#from-style {
                content: "keep; { 10vw";
                /* lead */ page-break-before/**/: always;
                -epub-writing-mode /* a */ \t/**/ : vertical-rl;
                width: 1e1vw;
                --label: "page-break-before/**/: 10vw";
                --url: url("https://example.com/10vw");
            }
            ${String.raw`#exact { --mode\{: vertical-rl; -epub-writing-mode: var(--mode\{); }`}`
            const baseAttribute = `content: 'keep; { 10vw'; /* lead */ -epub-writing-mode/**/: vertical-rl;
                page-break-inside /* a */\t/**/: avoid; width: -1e-1vw;
                --label: page-break-before/**/:value;`
            const checked = []
            for (const mediaType of ['text/html', 'application/xhtml+xml']) {
                for (const [identifier, prefixed] of [
                    [String.raw`--mode\{`, true], [String.raw`--mode\7b `, true],
                    [String.raw`--mode\00007b`, true], [String.raw`--mode\\\{`, true],
                    [String.raw`--mode\5c \{`, true], ['--mode', false],
                ]) {
                    const breakIdentifier = identifier.replace('--mode', '--break')
                    let sheet = baseSheet.replace('#from-style {',
                        `#from-style { ${identifier}: vertical-rl; ${breakIdentifier}: always;`)
                    // Replace only the intended property value, preserving the
                    // escaped variable's authored name and declaration bytes.
                    sheet = sheet.replace('-epub-writing-mode /* a */ \t/**/ : vertical-rl;',
                        `-epub-writing-mode /* a */ \t/**/ : var(${identifier});`)
                        .replace('page-break-before/**/: always;',
                            `page-break-before/**/: var(${breakIdentifier});`)
                    let attribute = `${identifier}: vertical-rl; ` + baseAttribute
                        .replace('-epub-writing-mode/**/: vertical-rl;',
                            `-epub-writing-mode/**/: var(${identifier});`)
                    if (!prefixed) {
                        sheet = sheet.replace('-epub-writing-mode', 'writing-mode')
                        attribute = attribute.replace('-epub-writing-mode', 'writing-mode')
                    }
                    const expectedSheet = sheet
                        .replace('page-break-before/**/:', '-webkit-column-break-before/**/:')
                        .replace('-epub-writing-mode /* a */', 'writing-mode /* a */')
                        .replace('width: 1e1vw', 'width: 80px')
                        .replace('-epub-writing-mode: var(', 'writing-mode: var(')
                    const item = { href: 'OPS/chapter.xhtml', mediaType }
                    const source = `<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>
                        <title>Inline CSS</title><style>${sheet}</style></head><body>
                        <p id="from-style">Style element</p><p id="exact">Exact escaped-brace case</p>
                        <p id="from-attribute" style="${attribute}">Style attribute</p>
                        </body></html>`
                    // XML normalizes attribute whitespace during the caller's
                    // first parse; compare against that real DOM value.
                    const originalAttribute = new DOMParser().parseFromString(source, mediaType)
                        .querySelector('#from-attribute').getAttribute('style')
                    const expectedAttribute = originalAttribute
                        .replace('-epub-writing-mode/**/:', 'writing-mode/**/:')
                        .replace('page-break-inside /* a */', '-webkit-column-break-inside /* a */')
                        .replace('width: -1e-1vw', 'width: -0.8px')
                    const loader = new Loader({ resources: { manifest: [item] },
                        loadText: async () => source,
                        loadBlob: async () => { throw new Error('unexpected raw resource') },
                    })
                    const frame = document.createElement('iframe')
                    try {
                        const url = await loader.loadItem(item)
                        const output = await (await fetch(url)).text()
                        const parsed = new DOMParser().parseFromString(output, mediaType)
                        check(!parsed.querySelector('parsererror'), 'serialized chapter must parse')
                        check(parsed.querySelector('style').textContent === expectedSheet, 'style element preserves protected text/comments')
                        check(parsed.querySelector('#from-attribute').getAttribute('style') === expectedAttribute,
                            'style attribute preserves protected text/comments')
                        await new Promise((resolve, reject) => {
                            frame.onload = resolve
                            frame.onerror = () => reject(new Error('chapter frame failed'))
                            frame.src = url
                            document.body.append(frame)
                        })
                        const doc = frame.contentDocument
                        const styleTarget = doc.querySelector('#from-style')
                        const attributeTarget = doc.querySelector('#from-attribute')
                        const style = frame.contentWindow.getComputedStyle(styleTarget)
                        check(style.writingMode === 'vertical-rl', 'style element affects actual layout style')
                        check(frame.contentWindow.getComputedStyle(doc.querySelector('#exact')).writingMode === 'vertical-rl',
                            'exact escaped-brace case affects actual layout style')
                        check(style.width === '80px', 'viewport exponent dimension is adapted')
                        check(frame.contentWindow.getComputedStyle(attributeTarget).writingMode === 'vertical-rl',
                            'style attribute affects actual layout style')
                        // Prefixed inline aliases may serialize as empty even when
                        // parsed. Assert the effective canonical fragmentation policy.
                        check(frame.contentWindow.getComputedStyle(attributeTarget).getPropertyValue('break-inside') === 'avoid',
                            'style attribute preserves effective break avoidance')
                        check(style.getPropertyValue('break-before') === 'column',
                            'style element preserves the effective forced column break')
                    } finally {
                        frame.remove()
                        loader.destroy()
                    }
                }
                checked.push(mediaType)
            }
            return checked
        }""")
        self.assertEqual(result, ['text/html', 'application/xhtml+xml'])

    def test_css_layout_adaptation_preserves_selectors_and_scientific_dimensions(self):
        page = self.browser.new_page(viewport={'width': 390, 'height': 844})
        self.addCleanup(page.close)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        result = page.evaluate('''async () => {
            const {Loader} = await import('./epub.js');
            const loader = new Loader({resources:{manifest:[]},loadText:async()=>null,loadBlob:async()=>null});
            const frame = document.createElement('iframe');
            document.body.append(frame);
            try {
                const source = '@media (min-width: 0px) { .w10vw#page-break-before.has-epub-marker {'
                    + ' width: 1e2vw; height: 1e1vh; --epub-size: 2e1px; font-size: var(--epub-size);'
                    + ' -epub-writing-mode: horizontal-tb; page-break-before: always; } }';
                const css = await loader.replaceCSS(source,'OPS/book.css');
                const doc = frame.contentDocument;
                const style = doc.createElement('style');
                style.textContent = css;
                doc.head.append(style);
                const target = doc.createElement('div');
                target.id = 'page-break-before';
                target.className = 'w10vw has-epub-marker';
                doc.body.append(target);
                const computed = frame.contentWindow.getComputedStyle(target);
                return {css, width:parseFloat(computed.width), height:parseFloat(computed.height),
                    fontSize:computed.fontSize,writingMode:computed.writingMode,
                    breakBefore:computed.webkitColumnBreakBefore,
                    viewportWidth:innerWidth,viewportHeight:innerHeight};
            } finally { frame.remove(); loader.destroy(); }
        }''')
        self.assertIn('.w10vw#page-break-before.has-epub-marker', result['css'])
        self.assertIn('--epub-size: 2e1px', result['css'])
        self.assertAlmostEqual(result['width'], result['viewportWidth'], places=2)
        self.assertAlmostEqual(result['height'], result['viewportHeight'] / 10, places=1)
        self.assertEqual(result['fontSize'], '20px')
        self.assertEqual(result['writingMode'], 'horizontal-tb')
        self.assertEqual(result['breakBefore'], 'always')

    def test_search_cfis_target_processed_structure_from_raw_archive(self):
        processed = {f'OPS/{name}.xhtml': prepared_chapter(name) for name in ['one', 'two']}
        def raw_chapter(name):
            return re.sub(r'</?m-(?:s|m|t)\b[^>]*>', '', processed[f'OPS/{name}.xhtml'])
        self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
        path = '/search-processed-structure.epub'
        self.server.epub_fixtures[path] = make_epub(raw_chapter)
        self.addCleanup(self.server.epub_fixtures.pop, path)
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.add_init_script("""(() => {
            const processed = """ + json.dumps(processed) + """;
            const originalFetch = window.fetch.bind(window);
            window.processedDocumentRequests = [];
            window.fetch = (input, options) => {
                const url = new URL(typeof input === 'string' ? input : input.url, location.href);
                if (url.protocol === 'ebook:' && url.pathname === '/processed-section') {
                    const subpath = url.searchParams.get('subpath');
                    processedDocumentRequests.push(subpath);
                    return Promise.resolve(new Response(processed[subpath] ?? '', {
                        status:processed[subpath] ? 200 : 404,
                        headers:{'Content-Type':'text/html; charset=utf-8', 'X-Manabi-Processing-Authoritative':'true'}
                    }));
                }
                return originalFetch(input, options);
            };
        })();""")
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/search-processed-structure.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'reader?.initialDisplaySettled === true')
        result = page.evaluate("""async () => {
            const view = reader.view;
            const raw = new DOMParser().parseFromString(await view.book.loadText('OPS/one.xhtml'), 'application/xhtml+xml');
            const liveState = () => ({hrefs:[...__manabiLiveProcessedSectionHrefs],
                first:__manabiFirstLiveSectionHref, inflight:__manabiInflightLiveReplaceTextCount ?? 0});
            const liveBefore = liveState();
            await view.book.sections[1].createDocument();
            const detached = await view.book.sections[0].createDocument();
            const rendered = view.renderer.getContents().find(content => content.index === 0).doc;
            const hits = [];
            for await (const result of view.search({query:'猫',index:0})) {
                if (!result?.excerpt) continue;
                const range = view.resolveCFI(result.cfi).anchor(rendered);
                hits.push({text:range.toString(),match:result.excerpt.match,
                    inSegment:range.startContainer.parentElement.closest('m-t') !== null});
            }
            return {rawSegments:raw.querySelectorAll('m-m').length,
                detachedSegments:detached.querySelectorAll('m-m').length,
                renderedSegments:rendered.querySelectorAll('m-m').length, hits,
                liveBefore, liveAfter:liveState(), requests:[...processedDocumentRequests]};
        }""")
        self.assertEqual(result['liveAfter'], result['liveBefore'])
        self.assertIn('OPS/two.xhtml', result['requests'])
        self.assertEqual(result['rawSegments'], 0)
        self.assertEqual(result['detachedSegments'], 1)
        self.assertEqual(result['renderedSegments'], 1)
        self.assertEqual(result['hits'], [{'text':'猫','match':'猫','inSegment':True}])

    def test_search_svg_spine_documents_and_later_html_keep_valid_cfis(self):
        def chapter(name):
            text = prepared_chapter(name)
            return text.replace('</body>', '<p id="after-svg">HTMLneedle</p></body>') if name == 'two' else text
        output = BytesIO()
        with zipfile.ZipFile(BytesIO(make_epub(chapter))) as original, zipfile.ZipFile(output, 'w') as archive:
            for info in original.infolist():
                content = original.read(info)
                if info.filename == 'OPS/book.opf':
                    content = content.decode().replace('<item id="two"',
                        '<item id="graphic" href="graphic.svg" media-type="image/svg+xml"/><item id="two"')
                    content = content.replace('<itemref idref="two"/>', '<itemref idref="graphic"/><itemref idref="two"/>').encode()
                archive.writestr(info, content)
            archive.writestr('OPS/graphic.svg', '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800">'
                '<title>titleneedle</title><desc>descneedle</desc><metadata>metadataneedle</metadata>'
                '<defs><text>defsneedle</text></defs><symbol><text>symbolneedle</text></symbol>'
                '<text id="svg-text" x="20" y="40">SVGneedle</text>'
                '<text id="svg-inline" x="20" y="80">read<tspan>ing</tspan></text>'
                '<text id="svg-label-one" x="20" y="120">joined</text>'
                '<text id="svg-label-two" x="20" y="160"><tspan>labels</tspan></text></svg>')
        self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
        path = '/search-svg-spine.epub'
        self.server.epub_fixtures[path] = output.getvalue()
        self.addCleanup(self.server.epub_fixtures.pop, path)
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/search-svg-spine.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'reader?.initialDisplaySettled === true')
        result = page.evaluate("""async () => {
            const view = reader.view;
            const svg = await view.book.sections[1].createDocument();
            const html = await view.book.sections[2].createDocument();
            const matches = [];
            let done = false;
            for await (const result of view.search({query:'needle'})) {
                if (result === 'done') done = true;
                for (const hit of result?.subitems ?? []) {
                    const resolved = view.resolveCFI(hit.cfi);
                    const range = resolved.anchor(resolved.index === 1 ? svg : html);
                    matches.push({index:resolved.index,text:range.toString(),match:hit.excerpt.match,
                        parent:range.startContainer.parentElement.localName});
                }
            }
            const direct = [];
            for await (const hit of view.search({query:'SVGneedle',index:1})) {
                if (!hit?.excerpt) continue;
                direct.push(view.resolveCFI(hit.cfi).anchor(svg).toString());
            }
            const phrases = {};
            for (const query of ['reading','joinedlabels','joined']) {
                phrases[query] = [];
                for await (const hit of view.search({query,index:1,matchWholeWords:true})) {
                    if (!hit?.excerpt) continue;
                    const range = view.resolveCFI(hit.cfi).anchor(svg);
                    phrases[query].push({text:range.toString(),start:range.startContainer.parentElement.closest('text').id,
                        end:range.endContainer.parentElement.closest('text').id});
                }
            }
            return {svgBody:svg.body,svgRoot:svg.documentElement.localName,matches,direct,phrases,done};
        }""")
        self.assertIsNone(result['svgBody'])
        self.assertEqual(result['svgRoot'], 'svg')
        self.assertEqual(result['matches'], [{'index':1,'text':'needle','match':'needle','parent':'text'},
                                            {'index':2,'text':'needle','match':'needle','parent':'p'}])
        self.assertEqual(result['direct'], ['SVGneedle'])
        self.assertEqual(result['phrases'], {'reading':[{'text':'reading','start':'svg-inline','end':'svg-inline'}],
            'joinedlabels':[], 'joined':[{'text':'joined','start':'svg-label-one','end':'svg-label-one'}]})
        self.assertTrue(result['done'])

    def test_search_ruby_base_text_keeps_processed_cfi_structure(self):
        authored = ('<p id="generated-ruby">漢字を</p>'
                    '<p id="authored-ruby"><ruby>東京<rp>（</rp><rt>とうきょう</rt><rp>）</rp></ruby>へ</p>'
                    '<p id="complex-ruby"><ruby><rb>大阪</rb><rtc><rt>おおさか</rt></rtc></ruby>に</p>')
        generated = ('<m-s><m-m id="mnb-ruby"><ruby class="mnb-gen"><m-t>漢字</m-t>'
                     '<rt>かんじ</rt></ruby><m-t>を</m-t></m-m></m-s>')
        def raw_chapter(name):
            return prepared_chapter(name).replace('</body>', authored + '</body>')
        processed = {f'OPS/{name}.xhtml': raw_chapter(name).replace(
            '<p id="generated-ruby">漢字を</p>', f'<p id="generated-ruby">{generated}</p>') for name in ['one','two']}
        self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
        path = '/search-ruby.epub'
        self.server.epub_fixtures[path] = make_epub(raw_chapter)
        self.addCleanup(self.server.epub_fixtures.pop, path)
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.add_init_script("""(() => {
            const processed = """ + json.dumps(processed) + """;
            const originalFetch = window.fetch.bind(window);
            window.fetch = (input, options) => {
                const url = new URL(typeof input === 'string' ? input : input.url, location.href);
                if (url.protocol === 'ebook:' && url.pathname === '/processed-section') {
                    const html = processed[url.searchParams.get('subpath')];
                    return Promise.resolve(new Response(html ?? '', {status:html ? 200 : 404,
                        headers:{'Content-Type':'text/html; charset=utf-8','X-Manabi-Processing-Authoritative':'true'}}));
                }
                return originalFetch(input, options);
            };
        })();""")
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/search-ruby.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'reader?.initialDisplaySettled === true')
        result = page.evaluate("""async () => {
            const view = reader.view;
            const raw = new DOMParser().parseFromString(await view.book.loadText('OPS/one.xhtml'),'application/xhtml+xml');
            const detached = await view.book.sections[0].createDocument();
            const rendered = view.renderer.getContents().find(content=>content.index===0).doc;
            const annotationCount = doc=>doc.querySelectorAll('rt,rp,rtc').length;
            const before = [annotationCount(detached),annotationCount(rendered)];
            const run = async query => {
                const hits = [];
                for await (const hit of view.search({query,index:0})) {
                    if (!hit?.excerpt) continue;
                    const range = view.resolveCFI(hit.cfi).anchor(rendered);
                    const surface = range.cloneContents();
                    surface.querySelectorAll('rt,rp,rtc').forEach(node=>node.remove());
                    hits.push({match:hit.excerpt.match,surface:surface.textContent,
                        id:range.startContainer.parentElement.closest('p').id,
                        start:range.startContainer.parentElement.localName,end:range.endContainer.parentElement.localName,
                        startOffset:range.startOffset,endOffset:range.endOffset});
                }
                return hits;
            };
            const generated = await run('漢字を'), authored = await run('東京へ'), complex = await run('大阪に');
            const annotations = [];
            for (const query of ['かんじ','かんじを','とうきょう','おおさか','（','）']) annotations.push(...await run(query));
            return {rawGeneratedAnnotations:raw.querySelectorAll('#generated-ruby rt').length,
                before,after:[annotationCount(detached),annotationCount(rendered)],generated,authored,complex,annotations};
        }""")
        def match(text, element_id, start, end):
            return {'match':text,'surface':text,'id':element_id,'start':start,'end':end,'startOffset':0,'endOffset':1}
        self.assertEqual(result['rawGeneratedAnnotations'], 0)
        self.assertEqual(result['before'], [6,6])
        self.assertEqual(result['after'], result['before'])
        self.assertEqual(result['generated'], [match('漢字を','generated-ruby','m-t','m-t')])
        self.assertEqual(result['authored'], [match('東京へ','authored-ruby','ruby','p')])
        self.assertEqual(result['complex'], [match('大阪に','complex-ruby','rb','p')])
        self.assertEqual(result['annotations'], [])

    def test_search_unvisited_invalid_xhtml_uses_html_fallback(self):
        def chapter(name):
            text = prepared_chapter(name)
            if name == 'two':
                text = text.replace('</body>', '<p id="malformed-search">needle & searchable</p></body>')
            return text
        self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
        path = '/search-invalid-xhtml.epub'
        self.server.epub_fixtures[path] = make_epub(chapter)
        self.addCleanup(self.server.epub_fixtures.pop, path)
        page = self.browser.new_page(viewport={'width': 390, 'height': 844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/search-invalid-xhtml.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'reader?.initialDisplaySettled === true')
        result = page.evaluate('''async () => {
            const view = reader.view;
            const item = view.book.resources.getItemByHref('OPS/two.xhtml');
            const initialType = item.mediaType;
            const source = await view.book.loadText(item.href);
            const invalidXML = !!new DOMParser().parseFromString(source,'application/xhtml+xml').querySelector('parsererror');
            const detached = await view.book.sections[1].createDocument();
            const matches = [];
            let done = false;
            for await (const result of view.search({query:'needle'})) {
                if (result === 'done') done = true;
                for (const match of result?.subitems ?? []) {
                    const resolved = view.resolveCFI(match.cfi);
                    const range = resolved.anchor(detached);
                    matches.push({match:match.excerpt.match,index:resolved.index,text:range.toString()});
                }
            }
            return {initialType,invalidXML,contentType:detached.contentType,
                body:!!detached.body,matches,done};
        }''')
        self.assertEqual(result['initialType'], 'application/xhtml+xml')
        self.assertTrue(result['invalidXML'])
        self.assertEqual(result['contentType'], 'text/html')
        self.assertTrue(result['body'])
        self.assertEqual(result['matches'], [{'match':'needle','index':1,'text':'needle'}])
        self.assertTrue(result['done'])

    def test_uri_navigation_snapshot_and_raw_warm_identity(self):
        for with_toc in (True, False):
            with self.subTest(with_toc=with_toc):
                archive, directory, names = make_uri_epub(with_toc)
                self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
                path = f'/uri-navigation-{with_toc}.epub'
                self.server.epub_fixtures[path] = archive
                self.addCleanup(self.server.epub_fixtures.pop, path)
                page = self.browser.new_page(viewport={'width': 390, 'height': 844})
                self.addCleanup(page.close)
                page.add_init_script(BRIDGE)
                page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
                wait_for_reader(page, 'typeof window.loadEBook === "function"')
                page.evaluate('(path) => loadEBook({url:location.origin+path,layoutMode:"paginated"})', path)
                wait_for_reader(page, 'reader?.initialDisplaySettled === true')
                canonical = [quote(directory + '/' + name, safe='/') for name in names]
                raw = [directory + '/' + name for name in names]
                self.assertEqual(page.evaluate('reader.view.book.sections.map(s => s.id)'), raw)
                self.assertEqual(page.evaluate('reader.view.book.sections.map(s => s.href)'), canonical)
                first = page.evaluate('reader.buildGoToSheetSnapshot()')
                self.assertEqual(first['currentChapterHref'], canonical[0])
                self.assertEqual(first['currentChapterTitle'], 'Chapter 0' if with_toc else '100%')
                self.assertTrue(all(item['percent'] is not None for item in first['chapters']))
                locale = page.evaluate('''async () => {
                    const matches = [];
                    for await (const item of reader.view.search({query:'ı', index:0, matchDiacritics:true})) {
                        if (item?.excerpt) matches.push(item.excerpt.match);
                    }
                    return matches;
                }''')
                self.assertEqual(locale, ['I'])
                for i in range(1, len(names)):
                    page.evaluate('''() => reader.view.renderer.getContents()[0].doc.getElementById('uri-next').click()''')
                    wait_for_reader(page, f'reader.view.renderer.displayedIndex === {i} && reader.view.lastLocation?.index === {i}')
                    snapshot = page.evaluate('reader.buildGoToSheetSnapshot()')
                    self.assertEqual(snapshot['currentChapterHref'], canonical[i])
                warm = page.evaluate('''(raw) => {
                    manabi_syncLiveSettledSections({hrefs:raw.slice(0,3), firstLiveHref:raw[0]});
                    return {hrefs:[...__manabiLiveProcessedSectionHrefs], first:__manabiFirstLiveSectionHref};
                }''', raw)
                self.assertEqual(warm, {'hrefs': sorted(raw[:3]), 'first': raw[0]})

    def test_search_preserves_inline_words_blocks_locale_and_cfi_ranges(self):
        def chapter(name):
            examples = ('<p id="search-inline">read<span>ing</span></p>'
                        '<p id="search-prefix">read</p><p id="search-suffix">ing</p>'
                        '<div id="search-empty">read<div></div>ing</div>'
                        '<p id="search-locale">I zzz</p>')
            return prepared_chapter(name).replace('</body>', examples + '</body>')

        self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
        path = '/search-boundaries.epub'
        self.server.epub_fixtures[path] = make_epub(chapter)
        self.addCleanup(self.server.epub_fixtures.pop, path)
        page = self.browser.new_page(viewport={'width': 390, 'height': 844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/search-boundaries.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'reader?.initialDisplaySettled === true')
        results = page.evaluate('''async () => {
            const view = reader.view;
            const doc = await view.book.sections[0].createDocument();
            const run = async (query, options = {}) => {
                const matches = [];
                for await (const result of view.search({query, index:0, matchWholeWords:true, ...options})) {
                    if (!result?.excerpt) continue;
                    const resolved = view.resolveCFI(result.cfi);
                    const range = resolved.anchor(doc);
                    matches.push({match:result.excerpt.match, index:resolved.index,
                        start:range.startContainer.parentElement.closest('[id^="search-"]')?.id,
                        end:range.endContainer.parentElement.closest('[id^="search-"]')?.id,
                        startOffset:range.startOffset, endOffset:range.endOffset});
                }
                return matches;
            };
            return {joined:await run('reading'), partial:await run('read'),
                separated:await run('read ing'),
                locale:await run('ı', {matchWholeWords:false, matchDiacritics:true, defaultLocale:'tr'})};
        }''')
        def match(text, start, end, end_offset):
            return {'match': text, 'index': 0, 'start': start, 'end': end,
                    'startOffset': 0, 'endOffset': end_offset}
        self.assertEqual(results['joined'], [match('reading', 'search-inline', 'search-inline', 3)])
        self.assertEqual(results['partial'], [match('read', 'search-prefix', 'search-prefix', 4),
                                               match('read', 'search-empty', 'search-empty', 4)])
        self.assertEqual(results['separated'], [match('read\ning', 'search-prefix', 'search-suffix', 3),
                                                 match('read\ning', 'search-empty', 'search-empty', 3)])
        self.assertEqual(results['locale'], [match('I', 'search-locale', 'search-locale', 1)])

    def test_search_normalization_and_unicode_ranges(self):
        def chapter(name):
            examples = ('<p id="normalized-space">cat  <span>dog</span></p>'
                        '<p id="normalized-format">ca&#xAD;<span>t</span></p>'
                        '<p id="normalized-sharp">Stra<span>ße</span></p>'
                        '<p id="normalized-ligature">o<span>ﬃ</span>ce</p>'
                        '<p id="normalized-oe">c<span>œ</span>ur</p>'
                        '<p id="normalized-ae">c<span>æ</span>lum</p>')
            return prepared_chapter(name).replace('</body>', examples + '</body>')

        self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
        path = '/search-normalization.epub'
        self.server.epub_fixtures[path] = make_epub(chapter)
        self.addCleanup(self.server.epub_fixtures.pop, path)
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/search-normalization.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'reader?.initialDisplaySettled === true')
        results = page.evaluate('''async () => {
            const view = reader.view;
            const doc = await view.book.sections[0].createDocument();
            const run = async (query, options = {}) => {
                const matches = [];
                for await (const result of view.search({query,index:0,defaultLocale:'de',...options})) {
                    if (!result?.excerpt) continue;
                    const range = view.resolveCFI(result.cfi).anchor(doc);
                    matches.push({match:result.excerpt.match, text:range.toString(),
                        start:range.startContainer.parentElement.closest('p')?.id,
                        end:range.endContainer.parentElement.closest('p')?.id,
                        startOffset:range.startOffset, endOffset:range.endOffset});
                }
                return matches;
            };
            return {space:await run('cat  dog'), format:await run('ca\u00ADt'),
                sharp:await run('strasse'), ligature:await run('office'),
                oe:await run('coeur',{defaultLocale:'fr'}), ae:await run('caelum',{defaultLocale:'en'}),
                strict:await run('strasse', {matchDiacritics:true})};
        }''')
        def match(text, element_id, end_offset):
            return {'match':text, 'text':text, 'start':element_id, 'end':element_id,
                    'startOffset':0, 'endOffset':end_offset}
        self.assertEqual(results['space'], [match('cat  dog', 'normalized-space', 3)])
        self.assertEqual(results['format'], [match('cat', 'normalized-space', 3),
                                             match('ca\u00ADt', 'normalized-format', 1)])
        self.assertEqual(results['sharp'], [match('Straße', 'normalized-sharp', 2)])
        self.assertEqual(results['ligature'], [match('oﬃce', 'normalized-ligature', 2)])
        self.assertEqual(results['oe'], [match('cœur', 'normalized-oe', 2)])
        self.assertEqual(results['ae'], [match('cælum', 'normalized-ae', 3)])
        self.assertEqual(results['strict'], [])

    def test_xml_chapter_language_precedence_search_ranges_and_rendering(self):
        cases = [
            ('root', 'xml:lang="tr"', '', 'ı', None, 'ltr'),
            ('body', 'lang="en"', 'xml:lang="tr"', 'ı', 'en', 'ltr'),
            ('conflict', 'xml:lang="tr" lang="en"', '', 'ı', 'en', 'ltr'),
            ('unknown-root', 'xml:lang=""', '', 'i', None, ''),
            ('unknown-body', 'lang="tr"', 'xml:lang=""', 'i', 'tr', ''),
            ('html-body', 'xml:lang="tr"', 'lang="en"', 'i', None, 'ltr'),
            ('arabic', 'xml:lang="ar"', '', 'i', None, 'rtl'),
        ]
        for key, root_attrs, body_attrs, expected_query, root_lang, direction in cases:
            with self.subTest(language=key):
                def chapter(name):
                    value = prepared_chapter(name).replace('<html ', '<html ' + root_attrs + ' ', 1)
                    value = value.replace('<body ', '<body ' + body_attrs + ' ', 1)
                    return value.replace('</body>', '<p id="xml-language">I</p></body>')
                self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
                path = f'/xml-language-{key}.epub'
                self.server.epub_fixtures[path] = make_epub(chapter)
                self.addCleanup(self.server.epub_fixtures.pop, path)
                page = self.browser.new_page(viewport={'width':390, 'height':844})
                self.addCleanup(page.close)
                page.add_init_script(BRIDGE)
                page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
                wait_for_reader(page, 'typeof window.loadEBook === "function"')
                page.evaluate('(path) => loadEBook({url:location.origin+path,layoutMode:"paginated"})', path)
                wait_for_reader(page, 'reader?.initialDisplaySettled === true')
                results = page.evaluate('''async () => {
                    const view = reader.view;
                    const doc = await view.book.sections[0].createDocument();
                    const run = async query => {
                        const matches = [];
                        for await (const result of view.search({query,index:0,matchDiacritics:true})) {
                            if (!result?.excerpt) continue;
                            const range = view.resolveCFI(result.cfi).anchor(doc);
                            if (range.startContainer.parentElement.closest('p')?.id !== 'xml-language') continue;
                            matches.push({match:result.excerpt.match,text:range.toString(),
                                start:range.startOffset,end:range.endOffset});
                        }
                        return matches;
                    };
                    const root = view.renderer.getContents()[0].doc.documentElement;
                    return {i:await run('i'), dotless:await run('ı'),
                        rootLanguage:root.getAttribute('lang'),direction:root.dir};
                }''')
                expected = [{'match':'I','text':'I','start':0,'end':1}]
                self.assertEqual(results['i'], expected if expected_query == 'i' else [])
                self.assertEqual(results['dotless'], expected if expected_query == 'ı' else [])
                self.assertEqual(results['rootLanguage'], root_lang)
                self.assertEqual(results['direction'], direction)
                page.close()

    def test_skipped_spine_entry_preserves_href_and_cfi_navigation(self):
        self.server.epub_fixtures = getattr(self.server, 'epub_fixtures', {})
        self.server.epub_fixtures['/missing-spine-entry.epub'] = make_epub(missing_spine_entry=True)
        self.addCleanup(self.server.epub_fixtures.pop, '/missing-spine-entry.epub')
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/missing-spine-entry.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'reader?.initialDisplaySettled === true')
        first_cfi = page.evaluate('reader.view.lastLocation.cfi')
        content_cfi = page.evaluate("""() => {
            const { doc } = reader.view.renderer.getContents()[0]
            const range = doc.createRange()
            range.selectNodeContents(doc.body.querySelector('p') || doc.body)
            range.collapse(true)
            return reader.view.getCFI(0, range)
        }""")
        self.assertEqual(page.evaluate('reader.view.book.sections.map(section => section.id)'),
                         ['OPS/one.xhtml', 'OPS/two.xhtml'])
        self.assertEqual(page.evaluate('reader.view.book.sections.map(section => reader.view.book.resources.cfis.indexOf(section.cfi))'),
                         [1, 2])
        self.assertEqual(page.evaluate('reader.view.book.sections.map(section => reader.view.resolveCFI(section.cfi).index)'),
                         [0, 1])
        self.assertEqual(page.evaluate('reader.view.resolveNavigation("OPS/two.xhtml").index'), 1)
        page.evaluate('reader.goToHref("OPS/two.xhtml", "goToHref")')
        wait_for_reader(page, 'reader.view.renderer.displayedIndex === 1')
        page.evaluate('(cfi) => reader.view.goTo(cfi)', first_cfi)
        wait_for_reader(page, 'reader.view.renderer.displayedIndex === 0')
        page.evaluate('reader.goToHref("OPS/two.xhtml", "goToHref")')
        wait_for_reader(page, 'reader.view.renderer.displayedIndex === 1')
        page.evaluate('(cfi) => reader.view.goTo(cfi)', content_cfi)
        wait_for_reader(page, 'reader.view.renderer.displayedIndex === 0')

    def test_schema14_preserves_visible_scope_text_from_sidecar(self):
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/fixture.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'reader?.initialDisplaySettled === true')
        actual = page.evaluate("""() => {
            const doc = reader.view.renderer.getContents()[0].doc;
            const result = reader.visiblePageSegmentResult(doc, null, 'schema14-scope-test', {
                postLookupTargets: false, hydrateStatuses: false
            });
            const metadata = result.visibleSegments[0]?.segmentMetadata;
            return { text: metadata?.x, scope: metadata?.scopeText,
                paragraph: metadata?.paragraphScopeText };
        }""")
        expected = '昨日の午後、図書館で本を読みました。猫がいます。 one'
        self.assertEqual(actual, {'text': expected, 'scope': expected, 'paragraph': expected})

    def test_initial_zero_fraction_restore_is_satisfied_at_first_page(self):
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('''loadEBook({url:location.origin+"/fixture.epub",layoutMode:"paginated",
            initialRestore:{requestID:"initial-zero",cfi:"",fractionalCompletion:0}})''')
        page.locator('#loading-indicator').wait_for(state='hidden', timeout=15000)
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 0)
        self.assertEqual(page.evaluate('reader.view.lastLocation.fractionInSection'), 0)
        self.assertGreater(page.evaluate('reader.view.lastLocation.fraction'), 0.003)
        self.assertTrue(page.evaluate('reader.hasLoadedLastPosition'))
        self.assertEqual(page.evaluate('window.__manabiInitialRestoreResult.terminalState'), 'satisfied')

    def test_actual_viewer_end_page_does_not_mark_skipped_content(self):
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        errors = []; page.on('pageerror', lambda error: errors.append(str(error)))
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/fixture.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'globalThis.reader?.view?.renderer?.getContents?.().length > 0 && reader.bookEndcap')
        # Completion describes this short chapter's visible page end, even
        # when fraction navigation correctly selected the beginning.
        page.evaluate('loadLastPosition({cfi:"",fractionalCompletion:0,stateSettleTimeoutMs:1500})')
        self.assertGreater(page.evaluate('reader.view.lastLocation.fraction'), 0.003)
        self.assertEqual(page.evaluate('window.__manabiInitialRestoreResult.terminalState'), 'satisfied')
        self.assertTrue(page.evaluate('reader.hasLoadedLastPosition'))
        # A repeated same-page restore still needs an owned renderer receipt.
        page.evaluate('loadLastPosition({cfi:"",fractionalCompletion:0,stateSettleTimeoutMs:1500})')
        self.assertEqual(page.evaluate('window.__manabiInitialRestoreResult.terminalState'), 'satisfied')
        try:
            page.locator('#loading-indicator').wait_for(state='hidden', timeout=15000)
        except Exception:
            print('REVEAL DIAGNOSTICS', page.evaluate('''() => ({
                initial:reader.initialDisplaySettled,events:window.__manabiTimelineEvents,
                errors:window.nativeMessages.filter(x=>x.name==='readerOnError'),
                contents:reader.view.renderer.getContents().map(x=>({index:x.index,url:x.doc?.URL,text:x.doc?.body?.innerText,html:x.doc?.body?.innerHTML}))
            })'''))
            raise
        wait_for_reader(page, 'reader.bookReadingRuntime.state.ready')
        page.evaluate('reader.view.renderer.goTo({index:1,anchor:()=>1})')
        page.evaluate('reader.updateNavButtons()')
        wait_for_reader(page, 'reader.bookReadingRuntime.state.ready')
        page.locator('#loading-indicator').wait_for(state='hidden')
        metrics_before = page.evaluate('reader.view.renderer.pageMetrics()')
        topology_before = page.evaluate('JSON.stringify({sections:reader.view.book.sections.map(x=>x.id),toc:reader.view.book.toc})')
        marks_before = page.evaluate('JSON.stringify(persistedProgress)')
        page.evaluate('reader.markVisiblePageAsRead("browser-regression")')
        self.assertEqual(page.evaluate('bookActionRequests.length'), 0)
        self.assertFalse(page.evaluate('reader.bookEndcap.visible'))
        page.locator('#btn-scroll-right').click()
        page.get_by_role('button', name='Finish Book', exact=True).wait_for()
        metrics_after = page.evaluate('reader.view.renderer.pageMetrics()')
        self.assertEqual(metrics_after['pages'], metrics_before['pages'])
        self.assertEqual(metrics_after['size'], metrics_before['size'])
        self.assertEqual(page.evaluate('JSON.stringify({sections:reader.view.book.sections.map(x=>x.id),toc:reader.view.book.toc})'), topology_before)
        self.assertEqual(page.evaluate('bookActionRequests.length'), 0)
        page.get_by_role('button', name='Finish Book', exact=True).click()
        self.assertEqual(page.evaluate('bookActionRequests.length'), 1)
        self.assertEqual(page.evaluate('bookActionRequests[0].action'), 'finishBook')
        self.assertEqual(page.evaluate('JSON.stringify(persistedProgress)'), marks_before)
        self.assertEqual(page.get_by_role('heading', name='End of Book', exact=True).count(), 1)
        page.evaluate('replyToBookAction(bookActionRequests[0],false)')
        page.get_by_role('alert').wait_for()
        page.get_by_role('button', name='Finish Book', exact=True).click()
        page.evaluate('replyToBookAction(bookActionRequests[1],true)')
        page.get_by_role('heading', name='Finished', exact=True).wait_for()
        self.assertEqual(page.evaluate('persistedProgress.readSegmentIdentifiers'), ['previously-read-segment'])
        self.assertEqual(page.evaluate('persistedProgress.sentenceIdentifiersRead'), ['previously-read-sentence'])
        self.assertFalse(page.evaluate('nativeMessages.some(x=>["markAllSectionsAsRead","finishedReadingBook","startOver"].includes(x.name))'))
        page.locator('#btn-scroll-left').click()
        wait_for_reader(page, '!reader.bookEndcap.visible')
        self.assertEqual(page.evaluate('async () => (await reader.view.renderer.pageMetrics()).page'), metrics_before['page'])
        page.locator('#btn-scroll-right').click()
        page.get_by_role('button', name='Start Book Over', exact=True).click()
        self.assertEqual(page.evaluate('bookActionRequests[2].action'), 'startBookOver')
        self.assertTrue(page.evaluate('reader.bookEndcap.visible'))
        page.evaluate('replyToBookAction(bookActionRequests[2],true)')
        wait_for_reader(page, '!reader.bookEndcap.visible')
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 0)
        self.assertEqual(page.evaluate('persistedProgress.readSegmentIdentifiers'), [])
        self.assertEqual(page.evaluate('historicalReadIDs'), ['previously-read-segment'])
        self.assertEqual(page.evaluate('JSON.stringify({sections:reader.view.book.sections.map(x=>x.id),toc:reader.view.book.toc})'), topology_before)
        self.assertEqual(errors, [])

if __name__ == '__main__': unittest.main(verbosity=2)
