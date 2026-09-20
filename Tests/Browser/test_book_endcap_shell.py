"""Viewer-shell E2E with a generated EPUB and a deliberately simulated native bridge.
The real viewer, paginator, side controls, terminal UI, and reply dispatcher run.
This does not claim to exercise Realm, CloudKit, SwiftUI, or WKWebView admission.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from threading import Thread
import os
import unittest
import zipfile
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'Sources/LakeOfFireReader/Resources/Resources/foliate-js'


def make_epub():
    output = BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        archive.writestr('mimetype', 'application/epub+zip')
        archive.writestr('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''')
        archive.writestr('OPS/book.opf', '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">book-actions-test</dc:identifier><dc:title>Book Actions Test</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-09-19T00:00:00Z</meta></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="one"/><itemref idref="two"/></spine></package>''')
        archive.writestr('OPS/nav.xhtml', '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">First Chapter</a></li><li><a href="two.xhtml">Last Chapter</a></li></ol></nav></body></html>''')
        for name in ['one', 'two']:
            archive.writestr('OPS/' + name + '.xhtml', f'''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{name}</title></head><body><p>This is the {name} chapter. Some content remains deliberately unmarked.</p></body></html>''')
    return output.getvalue()


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def translate_path(self, path):
        prefix = '/load/viewer-assets/foliate-js/'
        clean = path.split('?', 1)[0]
        if clean.startswith(prefix):
            relative = Path(clean[len(prefix):])
            if '..' not in relative.parts:
                return str(ASSETS / relative)
        return super().translate_path(path)

    def do_GET(self):
        if self.path == '/fixture.epub':
            data = make_epub()
            self.send_response(200)
            self.send_header('Content-Type', 'application/epub+zip')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        super().do_GET()


BRIDGE = '''(() => {
    window.nativeMessages = [];
    window.bookActionRequests = [];
    window.persistedProgress = {
        readSegmentIdentifiers: ['previously-read-segment'],
        sentenceIdentifiersRead: ['previously-read-sentence'],
        articleMarkedAsFinished: false
    };
    const handlers = {};
    for (const name of ['ebookViewerInitialized','ebookViewerLoaded','markSectionAsRead',
        'pageMetadataUpdated','updateReadingProgress','ebookNativeMarkReadState',
        'ebookNavigationVisibility','readerOnError']) {
        handlers[name] = {postMessage(payload) { window.nativeMessages.push({name,payload}); }};
    }
    handlers.ebookBookAction = {postMessage(payload) {
        window.bookActionRequests.push(payload);
    }};
    window.webkit = {messageHandlers: handlers};
    window.replyToBookAction = async (request, ok) => {
        if (ok) {
            if (request.action === 'finishBook') window.persistedProgress.articleMarkedAsFinished = true;
            else {
                window.persistedProgress = {readSegmentIdentifiers:[],sentenceIdentifiersRead:[],articleMarkedAsFinished:false};
                await window.reader.view.renderer.firstSection();
            }
            window.reader.applyBookReadingProgress(window.persistedProgress, 'simulated-native-commit');
        }
        window.manabi_bookActionDidComplete(request.requestID, {
            ok, finished:window.persistedProgress.articleMarkedAsFinished,
            ...(ok ? {} : {error:'Simulated native write failure'})
        });
    };
})();'''


class BookEndcapShellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(ROOT)))
        Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.pw = sync_playwright().start()
        cls.browser = cls.pw.chromium.launch(headless=True)

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.pw.stop()
        cls.server.shutdown()
        cls.server.server_close()

    def test_actual_viewer_end_page_does_not_mark_skipped_content(self):
        page = self.browser.new_page(viewport={'width':390, 'height':844})
        self.addCleanup(page.close)
        page.add_init_script(BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        page.wait_for_function('typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/fixture.epub",layoutMode:"paginated"})')
        page.wait_for_function('reader?.view?.renderer?.getContents?.().length > 0 && reader.bookEndcap', timeout=20000)
        page.evaluate('reader.applyBookReadingProgress(persistedProgress,"native-fixture")')
        page.evaluate('reader.view.renderer.goTo({index:1,anchor:()=>1})')
        page.evaluate('reader.updateNavButtons()')
        metrics_before = page.evaluate('reader.view.renderer.pageMetrics()')
        topology_before = page.evaluate('JSON.stringify({sections:reader.view.book.sections.map(x=>x.id),toc:reader.view.book.toc})')
        marks_before = page.evaluate('JSON.stringify(persistedProgress)')
        # The real Mark Read entry must not become Finish Book on the last page.
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
        self.assertFalse(page.evaluate('nativeMessages.some(x=>x.name==="markAllSectionsAsRead")'))
        page.locator('#btn-scroll-left').click()
        page.wait_for_function('!reader.bookEndcap.visible')
        self.assertEqual(page.evaluate('reader.view.renderer.pageMetrics().page'), metrics_before['page'])
        page.locator('#btn-scroll-right').click()
        page.get_by_role('button', name='Start Book Over', exact=True).click()
        self.assertEqual(page.evaluate('bookActionRequests[2].action'), 'startBookOver')
        self.assertTrue(page.evaluate('reader.bookEndcap.visible'))
        page.evaluate('replyToBookAction(bookActionRequests[2],true)')
        page.wait_for_function('!reader.bookEndcap.visible')
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 0)
        self.assertEqual(page.evaluate('persistedProgress.readSegmentIdentifiers'), [])
        self.assertEqual(page.evaluate('JSON.stringify({sections:reader.view.book.sections.map(x=>x.id),toc:reader.view.book.toc})'), topology_before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
