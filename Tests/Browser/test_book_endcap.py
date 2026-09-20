"""Real Chromium renderer journeys, with native persistence explicitly simulated.
Run: python3 Tests/Browser/test_book_endcap.py
Requires playwright; no network or sample books are needed during the test run.
"""
from pathlib import Path
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from threading import Thread
import os, unittest
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args): pass

class BookEndcapBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(ROOT)))
        Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(executable_path=os.environ.get('CHROMIUM_PATH'),headless=True,args=['--no-sandbox'])
    @classmethod
    def tearDownClass(cls):
        cls.browser.close(); cls.playwright.stop(); cls.server.shutdown(); cls.server.server_close()
    def journey(self, dir='ltr', vertical=False, fixed=False, long=False, size=(390,844)):
        page = self.browser.new_page(viewport={'width':size[0], 'height':size[1]})
        self.addCleanup(page.close)
        errors=[]
        page.on('pageerror',lambda e:errors.append(str(e)))
        page.goto(f'http://127.0.0.1:{self.server.server_port}/Tests/Browser/book-endcap.html?dir={dir}&vertical={str(vertical).lower()}&fixed={str(fixed).lower()}&long={str(long).lower()}')
        try:
            page.wait_for_function('window.ready === true', timeout=12000)
        except Exception:
            self.fail('Renderer did not become ready: ' + repr(errors))
        self.assertFalse(page.evaluate('cap.visible'))
        self.assertEqual(page.evaluate('book.sections.length'),3)
        self.assertEqual(page.evaluate('book.toc.length'),2)
        page.evaluate('view.renderer.goTo({index:1,anchor:()=>1})')
        page.wait_for_function('currentChapterIndex() === 1')
        self.assertFalse(page.evaluate('cap.visible'))
        for _ in range(60):
            if page.evaluate('cap.visible'): break
            page.evaluate('view.renderer.next(undefined,{bypassPostTurnDuplicateSuppression:true})')
        self.assertTrue(page.evaluate('cap.visible'))
        before = page.evaluate('JSON.stringify({index:currentChapterIndex(),location:view.lastLocation,sections:book.sections.map(s=>s.id),toc:book.toc,readIDs,relocations:relocations.length})')
        metrics=page.evaluate('view.renderer.pageMetrics?.() ?? null')
        self.assertEqual(page.get_by_role('button',name='Finish Book',exact=True).count(),1)
        self.assertEqual(page.evaluate('actions'),[])
        self.assertEqual(page.evaluate('currentChapterIndex()'),1)
        page.evaluate('view.renderer.next()')
        self.assertEqual(page.evaluate('actions'),[])
        page.evaluate('window.failNext=true')
        page.get_by_role('button',name='Finish Book',exact=True).click()
        page.get_by_role('alert').wait_for()
        self.assertEqual(page.get_by_role('heading',name='End of Book',exact=True).count(),1)
        page.get_by_role('button',name='Finish Book',exact=True).click()
        page.get_by_role('heading',name='Finished',exact=True).wait_for()
        self.assertEqual(page.evaluate('JSON.stringify({index:currentChapterIndex(),location:view.lastLocation,sections:book.sections.map(s=>s.id),toc:book.toc,readIDs,relocations:relocations.length})'),before)
        after_metrics=page.evaluate('view.renderer.pageMetrics?.() ?? null')
        if metrics:
            self.assertEqual(after_metrics['pages'], metrics['pages'])
            self.assertEqual(after_metrics['size'], metrics['size'])
        back=page.locator('#prev' if dir=='ltr' else '#next')
        back.click()
        page.wait_for_function('!cap.visible')
        self.assertEqual(page.evaluate('currentChapterIndex()'),1)
        self.assertFalse(page.evaluate('view.inert'))
        page.evaluate('view.renderer.next(undefined,{bypassPostTurnDuplicateSuppression:true})')
        page.get_by_role('button',name='Start Book Over',exact=True).wait_for()
        page.get_by_role('button',name='Start Book Over',exact=True).click()
        page.wait_for_function('!cap.visible && currentChapterIndex()===0')
        self.assertEqual(page.evaluate('readIDs'),[])
        self.assertEqual(page.evaluate('book.sections.length'),3)
        page.evaluate('cap.enter()')
        page.evaluate('view.renderer.goTo({index:0})')
        self.assertFalse(page.evaluate('cap.visible'))
        self.assertEqual(errors,[])
    def test_portrait_short_ltr(self): self.journey()
    def test_portrait_long_rtl(self): self.journey(dir='rtl',long=True)
    def test_vertical_short_rtl(self): self.journey(dir='rtl',vertical=True)
    def test_vertical_long_rtl(self): self.journey(dir='rtl',vertical=True,long=True)
    def test_landscape_long_ltr(self): self.journey(long=True,size=(1024,768))
    def test_landscape_long_vertical(self): self.journey(dir='rtl',vertical=True,long=True,size=(1024,768))
    def test_fixed_layout_ltr(self): self.journey(fixed=True)
    def test_fixed_layout_rtl(self): self.journey(dir='rtl',fixed=True)

if __name__=='__main__': unittest.main(verbosity=2)
