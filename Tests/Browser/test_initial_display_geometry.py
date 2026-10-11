"""Actual viewer first-display ownership; native lookup builder/frame IDs are explicit collaborators. Uses native-shaped target publication with prepared sidecars."""
import unittest
import test_book_endcap_shell as shell
from browser_wait import wait_for_reader

NATIVE_TARGET_BRIDGE = """
    const fixtureFrameID = crypto.randomUUID();
    window.manabiCurrentFrameUUID = () => fixtureFrameID;
    window.manabi_nativeLookupHitTargetForSegment = (node, rects) => ({elementId:node.id,rects});
    window.webkit.messageHandlers.nativeLookupHitTargetsUpdated = {postMessage(payload) {window.top.nativeMessages.push({name:'nativeLookupHitTargetsUpdated',payload});}};
"""
DISPLAY_COMPLETION_BRIDGE = """
    window.displayCompletions = [];
    const originalAdd = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function(type, callback, options) {
        if (type === 'didDisplay' && callback?.constructor?.name === 'AsyncFunction') {
            const originalCallback = callback;
            callback = function(event) {
                const result = originalCallback.call(this, event);
                window.displayCompletions.push(result);
                return result;
            };
        }
        return originalAdd.call(this, type, callback, options);
    };
"""

class InitialDisplayGeometryTests(unittest.TestCase):
    setUpClass = classmethod(shell.BookEndcapShellTests.setUpClass.__func__)

    def test_geometry_refresh_during_first_display_reaches_publication_boundary(self):
        page = self.browser.new_page(viewport={'width':390,'height':844})
        self.addCleanup(page.close)
        try:
            page.add_init_script(shell.BRIDGE + """
                const fixtureFrameID = crypto.randomUUID();
                window.manabiCurrentFrameUUID = () => fixtureFrameID;
                window.manabi_nativeLookupHitTargetForSegment = (node, rects) => ({elementId:node.id,rects});
                window.webkit.messageHandlers.nativeLookupHitTargetsUpdated = {postMessage(payload) {window.top.nativeMessages.push({name:'nativeLookupHitTargetsUpdated',payload});}};
                window.displayGeometryInvalidation = null;
                const originalAdd = EventTarget.prototype.addEventListener;
                EventTarget.prototype.addEventListener = function(type, callback, options) {
                    if (type === 'didDisplay' && callback?.constructor?.name === 'AsyncFunction') {
                        const originalCallback = callback;
                        callback = function(event) {
                            const result = originalCallback.call(this, event);
                            if (!window.displayGeometryInvalidation && typeof window.manabiInvalidateVisiblePageSegmentSnapshot === 'function') {
                                const before = reader.visiblePageCollectionGeneration;
                                window.manabiInvalidateVisiblePageSegmentSnapshot('font-family-change-child');
                                window.displayGeometryInvalidation = {before,after:reader.visiblePageCollectionGeneration};
                                EventTarget.prototype.addEventListener = originalAdd;
                            }
                            return result;
                        };
                    }
                    return originalAdd.call(this, type, callback, options);
                };
            """)
            page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
            wait_for_reader(page, 'typeof window.loadEBook === "function"')
            page.evaluate('loadEBook({url:location.origin+"/fixture.epub",layoutMode:"paginated"})')
            wait_for_reader(page, 'globalThis.reader?.view?.renderer?.getContents?.().length > 0 && reader.bookEndcap')
            page.evaluate('loadLastPosition({})')
            wait_for_reader(page, '!!window.displayGeometryInvalidation')
            wait_for_reader(page, "reader.hasReachedLoadingDidDisplayBoundary === true && nativeMessages.some(x=>x.name==='nativeLookupHitTargetsUpdated' && x.payload.isExplicitReset === false && x.payload.targets.length > 0)", timeout=15000)
            self.assertEqual(page.evaluate('document.documentElement.dataset.mnbReaderRenderReady'), '1')
            self.assertTrue(page.evaluate('reader.initialDisplaySettled'))
        finally:
            print('DISPLAY GEOMETRY STATE',page.evaluate("""() => ({invalidation:window.displayGeometryInvalidation,ready:document.documentElement.dataset.mnbReaderRenderReady,bodyClasses:document.body.className,settled:globalThis.reader?.initialDisplaySettled,boundary:globalThis.reader?.hasReachedLoadingDidDisplayBoundary,restoreAttempt:globalThis.reader?.hasCompletedLastPositionLoadAttempt,targets:(window.nativeMessages??[]).filter(x=>x.name==='nativeLookupHitTargetsUpdated').map(x=>({reason:x.payload.reason,count:x.payload.targets?.length})),errors:(window.nativeMessages??[]).filter(x=>x.name==='readerOnError')})"""))

    def open_ready_page(self):
        page = self.browser.new_page(viewport={'width':390,'height':844})
        self.addCleanup(page.close)
        page.add_init_script(shell.BRIDGE + NATIVE_TARGET_BRIDGE + DISPLAY_COMPLETION_BRIDGE)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/fixture.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'globalThis.reader?.view?.renderer?.getContents?.().length > 0 && reader.bookEndcap')
        page.evaluate('loadLastPosition({})')
        try:
            wait_for_reader(page, "reader.hasReachedLoadingDidDisplayBoundary && nativeMessages.some(x=>x.name==='nativeLookupHitTargetsUpdated' && x.payload.targets.length>0)")
        except Exception:
            print('SETUP STATE', page.evaluate("""() => ({ready:document.documentElement.dataset.mnbReaderRenderReady,boundary:reader.hasReachedLoadingDidDisplayBoundary,settled:reader.initialDisplaySettled,attempt:reader.hasCompletedLastPositionLoadAttempt,loading:document.body.className,restore:globalThis.__manabiRestoreInProgress,displayCount:displayCompletions.length,targets:nativeMessages.filter(x=>x.name==='nativeLookupHitTargetsUpdated'),doc:reader.view.renderer.getContents().map(x=>({index:x.index,displayed:x.isDisplayed,body:x.doc?.body?.innerText}))})"""))
            raise
        page.evaluate('Promise.all(displayCompletions)')
        return page

    def pause_display(self, page):
        page.evaluate("""() => {
            window.testRenderer = reader.view.renderer;
            window.testDocument = testRenderer.getContents()[0].doc;
            window.originalSettle = testRenderer.renderIfContainerSizeChanged;
            testRenderer.renderIfContainerSizeChanged = () => new Promise(resolve => {window.releaseDisplay = () => resolve({rendered:false,reason:'test-held'});});
            reader.hasSettledInitialPaginatorLayout = false;
            reader.hasReachedLoadingDidDisplayBoundary = false;
            reader.setLoadingIndicator(true, 'test-display');
            delete document.documentElement.dataset.mnbReaderRenderReady;
            testRenderer.dispatchEvent(new CustomEvent('didDisplay'));
            window.heldDisplay = displayCompletions.at(-1);
            testRenderer.renderIfContainerSizeChanged = originalSettle;
        }""")

    def test_closed_reader_rejects_held_display(self):
        page = self.open_ready_page()
        self.pause_display(page)
        result = page.evaluate("""async () => {
            reader.close('test-held-display');
            releaseDisplay(); await heldDisplay;
            return {boundary:reader.hasReachedLoadingDidDisplayBoundary,ready:document.documentElement.dataset.mnbReaderRenderReady};
        }""")
        self.assertFalse(result['boundary'])
        self.assertNotEqual(result.get('ready'), '1')

    def test_replaced_document_rejects_held_display(self):
        page = self.open_ready_page()
        self.pause_display(page)
        result = page.evaluate("""async () => {
            const originalContents = testRenderer.getContents;
            const replacement = document.implementation.createHTMLDocument('replacement');
            testRenderer.getContents = () => [{doc:replacement,index:0}];
            try {
                releaseDisplay(); await heldDisplay;
                return {boundary:reader.hasReachedLoadingDidDisplayBoundary,ready:document.documentElement.dataset.mnbReaderRenderReady,loading:document.body.classList.contains('loading')};
            } finally {testRenderer.getContents = originalContents;}
        }""")
        self.assertFalse(result['boundary'])
        self.assertNotEqual(result.get('ready'), '1')
        self.assertTrue(result['loading'])

    def test_newer_display_rejects_held_completion(self):
        page = self.open_ready_page()
        self.pause_display(page)
        page.evaluate("""async () => {
            reader.hasSettledInitialPaginatorLayout = true;
            testRenderer.dispatchEvent(new CustomEvent('didDisplay'));
            await displayCompletions.at(-1);
        }""")
        self.assertTrue(page.evaluate('reader.hasReachedLoadingDidDisplayBoundary'))
        # A sentinel cover belongs to subsequent work. Releasing the older
        # callback must not clear it after the newer display has completed.
        page.evaluate("""async () => {
            reader.setLoadingIndicator(true, 'new-owner-cover');
            reader.hasReachedLoadingDidDisplayBoundary = false;
            delete document.documentElement.dataset.mnbReaderRenderReady;
            releaseDisplay(); await heldDisplay;
        }""")
        self.assertTrue(page.evaluate("document.body.classList.contains('loading')"))
        self.assertFalse(page.evaluate('reader.hasReachedLoadingDidDisplayBoundary'))
        self.assertNotEqual(page.evaluate('document.documentElement.dataset.mnbReaderRenderReady'), '1')

    def test_geometry_change_at_paint_resamples_visibility(self):
        page = self.open_ready_page()
        result = page.evaluate("""async () => {
            const renderer = reader.view.renderer;
            const doc = renderer.getContents()[0].doc;
            const originalRAF = window.requestAnimationFrame;
            window.requestAnimationFrame = callback => originalRAF(timestamp => {
                window.requestAnimationFrame = originalRAF;
                doc.body.style.display = 'none';
                window.manabiInvalidateVisiblePageSegmentSnapshot('font-family-change-child');
                callback(timestamp);
            });
            reader.hasSettledInitialPaginatorLayout = true;
            reader.hasReachedLoadingDidDisplayBoundary = false;
            reader.setLoadingIndicator(true, 'test-paint');
            delete document.documentElement.dataset.mnbReaderRenderReady;
            try {
                renderer.dispatchEvent(new CustomEvent('didDisplay'));
                await displayCompletions.at(-1);
                return {boundary:reader.hasReachedLoadingDidDisplayBoundary,ready:document.documentElement.dataset.mnbReaderRenderReady,loading:document.body.classList.contains('loading')};
            } finally {
                window.requestAnimationFrame = originalRAF;
                doc.body.style.removeProperty('display');
            }
        }""")
        self.assertTrue(result['boundary'])
        self.assertNotEqual(result.get('ready'), '1')
        self.assertTrue(result['loading'])

    def test_new_document_navigation_rejects_held_display_before_commit(self):
        page = self.open_ready_page()
        self.pause_display(page)
        result = page.evaluate("""async () => {
            testRenderer.dispatchEvent(new CustomEvent('goTo', {detail:{willLoadNewIndex:true}}));
            releaseDisplay(); await heldDisplay;
            return {boundary:reader.hasReachedLoadingDidDisplayBoundary,ready:document.documentElement.dataset.mnbReaderRenderReady,loading:document.body.classList.contains('loading')};
        }""")
        self.assertFalse(result['boundary'])
        self.assertNotEqual(result.get('ready'), '1')
        self.assertTrue(result['loading'])

    def test_terminal_load_error_rejects_held_display(self):
        page = self.open_ready_page()
        self.pause_display(page)
        result = page.evaluate("""async () => {
            reader.setLoadingIndicator(false, 'loadEBook.error', {terminal:true});
            reader.close('loadEBook.error');
            delete document.documentElement.dataset.mnbReaderRenderReady;
            releaseDisplay(); await heldDisplay;
            return {boundary:reader.hasReachedLoadingDidDisplayBoundary,ready:document.documentElement.dataset.mnbReaderRenderReady};
        }""")
        self.assertFalse(result['boundary'])
        self.assertNotEqual(result.get('ready'), '1')
