"""Real Foliate sheets in the viewer; uses the maintained native-sidecar fixture.

Run with python3 -m unittest discover -s Tests/Browser -p test_layered_page_turn.py.
Set PAGE_TURN_BROWSER=webkit for desktop WebKit coverage.
Use Python Playwright 1.62 or newer with its matching browser installation.
"""
from functools import partial
from threading import Thread
import json
import os
import unittest
from playwright.sync_api import sync_playwright
import test_book_endcap_shell as shell
from browser_wait import wait_for_reader


class LayeredPageTurnTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = shell.ViewerAssetServer(('127.0.0.1', 0), partial(shell.Handler, directory=str(shell.ROOT)))
        cls.addClassCleanup(cls.server.server_close)
        Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.addClassCleanup(cls.server.shutdown)
        cls.pw = sync_playwright().start()
        cls.addClassCleanup(cls.pw.stop)
        engine = os.environ.get('PAGE_TURN_BROWSER', 'chromium')
        options = {'headless': True}
        if engine == 'webkit' and os.environ.get('WEBKIT_PATH'):
            options['executable_path'] = os.environ['WEBKIT_PATH']
        if engine == 'chromium':
            options.update(executable_path=os.environ.get('CHROMIUM_PATH'), args=['--disable-features=MacAppCodeSignClone'])
        cls.browser = getattr(cls.pw, engine).launch(**options)
        cls.addClassCleanup(cls.browser.close)

    def new_reader_page(self):
        page = self.browser.new_page(viewport={'width': 390, 'height': 844})
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))

        def close_and_check_errors():
            try:
                page.close()
            finally:
                self.assertEqual(errors, [], 'Reader page emitted uncaught JavaScript errors')

        self.addCleanup(close_and_check_errors)
        return page

    def open_reader(self, rtl=False, presentation=None, layout='paginated', page_turn=None):
        page = self.new_reader_page()
        page.set_default_timeout(15000)
        if presentation is not None:
            page.add_init_script('globalThis.__manabiReaderPresentationState=' + json.dumps(presentation))
        if page_turn is not None:
            page.add_init_script('globalThis.__manabiEbookPageTurnStyle=' + json.dumps(page_turn))
        page.add_init_script(shell.BRIDGE + """
            window.paginatorRoots = new WeakMap();
            const attach = Element.prototype.attachShadow;
            Element.prototype.attachShadow = function(options) {
                const root = attach.call(this, options);
                if (this.localName === 'foliate-paginator') paginatorRoots.set(this, root);
                return root;
            };
        """)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('layout => loadEBook({url:location.origin+"/fixture.epub",layoutMode:layout})', layout)
        wait_for_reader(page, 'globalThis.reader?.view?.renderer?.getContents?.().length > 0 && reader.bookEndcap')
        page.evaluate('loadLastPosition({})')
        page.locator('#loading-indicator').wait_for(state='hidden', timeout=15000)
        wait_for_reader(page, 'reader.initialDisplaySettled')
        page.evaluate("""rtl => {
            window.paginator = reader.view.renderer;
            window.originalDocument = paginator.getContents()[0].doc;
            window.relocations = []; window.commits = [];
            paginator.addEventListener('relocate', e => relocations.push({index:e.detail.index,reason:e.detail.reason}));
            paginator.addEventListener('document-committed', e => commits.push(e.detail.index));
            if (rtl) paginator.bookDir = 'rtl';
            window.pointer = (type, x, y=100) => paginator.dispatchEvent(new PointerEvent(type, {
                pointerId: 1, pointerType:'touch', isPrimary:true, button:0,
                clientX:x,clientY:y,bubbles:true,cancelable:true
            }));
        }""", rtl)
        return page

    def prepare(self, page, direction=1):
        page.evaluate('setEbookViewerPageTurnStyle("slide")')
        page.evaluate('async direction => { window.turn = await paginator.preparePageTurn(direction); return !!turn; }', direction)
        self.assertTrue(page.evaluate('!!turn'))

    def set_inset_reader_layout(self, page):
        # Model a stable inset text viewport without enabling the retired JS
        # chrome-inset bridge. Relocation must not reset this fixture layout.
        page.add_style_tag(content="""
            body { --mnb-reader-stage-top-inset: 59px !important;
                --mnb-toolbar-bottom-offset: 34px !important; }
            #reader-stage { top: 59px !important; }
        """)
        page.evaluate('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')

    def test_native_corner_radii_inherit_into_swipe_sheets(self):
        for rtl in [False, True]:
            with self.subTest(rtl=rtl):
                page = self.open_reader(rtl)
                page.evaluate('setEbookViewerPageTurnStyle("slide")')
                self.prepare(page)
                page.evaluate('turn.update(.4)')

                def corners():
                    return page.evaluate("""() => {
                        const root = paginatorRoots.get(paginator);
                        return [paginator, root.querySelector('#top:not(.mnb-slide-sheet)'),
                            root.querySelector('.mnb-slide-sheet'), ...root.querySelectorAll('.mnb-slide-paper, .mnb-slide-shade')]
                            .map(node => {
                                const style = getComputedStyle(node);
                                return [style.borderTopLeftRadius, style.borderTopRightRadius,
                                    style.borderBottomRightRadius, style.borderBottomLeftRadius];
                            });
                    }""")

                # Older iOS and Mac do not supply native radii at any viewport size.
                self.assertEqual(corners(), [['0px'] * 4] * 7)
                for value, expected in [
                    ('61px 47px 29px 0px', ['61px', '47px', '29px', '0px']),
                    ('0px', ['0px'] * 4),
                    ('32px 12px 0px 8px', ['32px', '12px', '0px', '8px']),
                ]:
                    page.evaluate("value => document.documentElement.style.setProperty('--reader-page-radius', value)", value)
                    actual = corners()
                    self.assertEqual(len(actual), 7)
                    self.assertEqual(actual, [expected] * 7)
                # Reused preview surfaces inherit the latest geometry too.
                page.evaluate('paginator.cancelPageTurn()')
                self.prepare(page)
                self.assertEqual(corners(), [['32px', '12px', '0px', '8px']] * 7)
                page.evaluate("document.documentElement.style.removeProperty('--reader-page-radius')")
                self.assertEqual(corners(), [['0px'] * 4] * 7)
                page.set_viewport_size({'width': 844, 'height': 390})
                wait_for_reader(page, '!paginator.hasAttribute("data-turn-progress")')
                self.assertEqual(page.evaluate('getComputedStyle(paginator).borderTopLeftRadius'), '0px')
                page.set_viewport_size({'width': 390, 'height': 844})
                self.assertEqual(page.evaluate('getComputedStyle(paginator).borderTopLeftRadius'), '0px')

    def test_slide_paper_fills_window_without_reflowing_safe_text(self):
        for rtl in [False, True]:
            with self.subTest(rtl=rtl):
                page = self.open_reader(rtl, presentation={'colorScheme': 'dark'} if rtl else None)
                self.set_inset_reader_layout(page)
                page.evaluate("""async () => {
                    window.sampleFrameLayout = iframe => {
                        const doc = iframe.contentDocument;
                        const text = doc.querySelector('m-t').firstChild;
                        const range = doc.createRange(); range.setStart(text,0); range.setEnd(text,1);
                        const glyph = range.getBoundingClientRect(), frame = iframe.getBoundingClientRect();
                        return [frame.x,frame.y,frame.width,frame.height,
                            frame.x+glyph.x,frame.y+glyph.y,glyph.width,glyph.height];
                    };
                    window.sampleTextLayout = () => sampleFrameLayout(paginator.getContents()[0].iframe);
                    window.beforeSlideLayout = sampleTextLayout();
                    setEbookViewerPageTurnStyle('slide');
                    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                }""")
                before = page.evaluate('beforeSlideLayout')
                paper_color = page.evaluate('getComputedStyle(paginatorRoots.get(paginator).querySelector(".mnb-slide-paper")).backgroundColor')
                self.assertGreater(before[1], 59, 'Text remains below native chrome and the top gutter')
                self.assertEqual(page.evaluate('sampleTextLayout()'), before)
                self.prepare(page)
                for progress in [0, .25, .5, .75, 1]:
                    result = page.evaluate("""progress => {
                        turn.update(progress);
                        const root = paginatorRoots.get(paginator);
                        const layers = [...root.querySelectorAll('.mnb-slide-paper, .mnb-slide-shade')]
                            .map(node => {
                                const rect = node.getBoundingClientRect();
                                return {top:rect.top,bottom:rect.bottom,width:rect.width};
                            });
                        return {layers,width:innerWidth,height:innerHeight,
                            paperColors:[...root.querySelectorAll('.mnb-slide-paper')].map(node => getComputedStyle(node).backgroundColor),
                            clipping:[document.getElementById('reader-stage'), reader.view, paginator,
                                root.querySelector('#top:not(.mnb-slide-sheet)')]
                                .map(node => getComputedStyle(node).overflow)};
                    }""", progress)
                    self.assertEqual(len(result['layers']), 4)
                    self.assertEqual(result['paperColors'], [paper_color] * 2)
                    self.assertEqual(result['clipping'], ['visible'] * 4)
                    for layer in result['layers']:
                        self.assertAlmostEqual(layer['top'], 0, delta=.5)
                        self.assertAlmostEqual(layer['bottom'], result['height'], delta=.5)
                        self.assertAlmostEqual(layer['width'], result['width'], delta=.5)
                page.evaluate('turn.cancel()')
                self.assertEqual(page.evaluate('sampleTextLayout()'), before)
                self.prepare(page)
                endpoint = page.evaluate("""async () => {
                    turn.update(1);
                    const preview = sampleFrameLayout(paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe'));
                    const moved = await turn.commit({allowBookEndcap:false});
                    await new Promise(requestAnimationFrame);
                    return {preview, committed:sampleTextLayout(), moved};
                }""")
                self.assertTrue(endpoint['moved'])
                self.assertEqual(page.evaluate('getComputedStyle(paginatorRoots.get(paginator).querySelector(".mnb-slide-paper")).backgroundColor'), paper_color)
                for preview, committed in zip(endpoint['preview'], endpoint['committed']):
                    self.assertAlmostEqual(preview, committed, delta=.5, msg='Inset text must not jump on commit')
                page.evaluate('setEbookViewerPageTurnStyle("instant")')
                self.assertEqual(page.evaluate('sampleTextLayout()'), endpoint['committed'])
                self.assertFalse(page.evaluate('reader.view.hasAttribute("data-slide-pages")'))
                self.assertEqual(page.evaluate('getComputedStyle(document.getElementById("reader-stage")).overflow'), 'hidden')

    def test_slide_paper_tracks_production_theme_during_drag_and_cleanup(self):
        page = self.open_reader()
        # Use the same palette stylesheet native injects into the viewer, not
        # a copy of its CSS rules or a guessed browser Canvas color.
        theme_css = shell.ROOT.parent / 'ManabiReaderCore/Sources/ManabiReaderCore/Resources/CSS/manabi_reader.css'
        page.add_style_tag(path=str(theme_css))
        page.evaluate('setEbookViewerPageTurnStyle("slide")')
        for scheme, light, dark, expected in [
            ('light', 'beige', 'black', 'rgb(247, 240, 216)'),
            ('dark', 'beige', 'gray', 'rgb(49, 50, 52)'),
            ('dark', 'beige', 'black', 'rgb(0, 0, 0)'),
            ('light', 'white', 'black', 'rgb(255, 255, 255)'),
        ]:
            with self.subTest(scheme=scheme, light=light, dark=dark):
                self.prepare(page)
                page.evaluate("""({scheme,light,dark}) => {
                    turn.update(.4);
                    Object.assign(document.body.dataset, {
                        mnbColorScheme:scheme, mnbLightTheme:light, mnbDarkTheme:dark,
                    });
                }""", {'scheme': scheme, 'light': light, 'dark': dark})
                colors = page.evaluate("""() => [...paginatorRoots.get(paginator).querySelectorAll('.mnb-slide-paper')]
                    .map(paper => getComputedStyle(paper).backgroundColor)""")
                self.assertEqual(colors, [expected, expected])
                page.evaluate('turn.cancel()')
                self.assertEqual(page.evaluate("getComputedStyle(paginatorRoots.get(paginator).querySelector('.mnb-slide-paper')).backgroundColor"), expected)
        self.prepare(page)
        page.evaluate("Object.assign(document.body.dataset, {mnbColorScheme:'light',mnbLightTheme:'beige'}); turn.update(1)")
        self.assertTrue(page.evaluate('turn.commit({allowBookEndcap:false})'))
        self.assertEqual(page.evaluate("getComputedStyle(paginatorRoots.get(paginator).querySelector('.mnb-slide-paper')).backgroundColor"), 'rgb(247, 240, 216)')

    def test_theme_updates_reach_held_preview_text_and_next_preparation(self):
        page = self.open_reader(presentation={
            'colorScheme': 'light', 'lightModeTheme': 'white', 'darkModeTheme': 'black',
        })
        theme_css = shell.ROOT.parent / 'ManabiReaderCore/Sources/ManabiReaderCore/Resources/CSS/manabi_reader.css'
        page.add_style_tag(path=str(theme_css))
        page.evaluate("""async css => {
            const install = doc => {
                const style=doc.createElement('style'); style.textContent=css; doc.head.append(style);
                doc.body.classList.add('readability-mode');
            };
            install(originalDocument);
            paginator.addEventListener('pageturnpreviewload', e => install(e.detail.doc));
            // Model the native theme writer's mutations of viewer and live
            // publication only. The preview must synchronize its own paint.
            window.applyFixtureTheme = ({scheme,light,dark}) => {
                for(const doc of [document, originalDocument]) {
                    Object.assign(doc.body.dataset,{mnbColorScheme:scheme,mnbLightTheme:light,mnbDarkTheme:dark});
                    doc.documentElement.style.setProperty('color-scheme',scheme);
                    doc.body.style.setProperty('color-scheme',scheme);
                }
            };
            applyFixtureTheme({scheme:'light',light:'white',dark:'black'});
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        }""", theme_css.read_text())
        previous_color = 'rgb(0, 0, 0)'
        for scheme, light, dark, color in [
            ('dark', 'white', 'black', 'rgb(217, 217, 217)'),
            ('light', 'beige', 'black', 'rgb(90, 76, 54)'),
            ('dark', 'beige', 'gray', 'rgb(217, 217, 217)'),
            ('light', 'white', 'gray', 'rgb(0, 0, 0)'),
        ]:
            with self.subTest(scheme=scheme, light=light, dark=dark):
                self.prepare(page)
                self.assertEqual(page.evaluate("getComputedStyle(paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe').contentDocument.querySelector('m-t')).color"), previous_color)
                result = page.evaluate("""async theme => {
                    turn.update(.4);
                    applyFixtureTheme(theme);
                    await new Promise(requestAnimationFrame);
                    const root=paginatorRoots.get(paginator), sheet=root.querySelector('.mnb-slide-sheet');
                    const doc=sheet.querySelector('iframe').contentDocument;
                    return {preview:getComputedStyle(doc.querySelector('m-t')).color,
                        live:getComputedStyle(originalDocument.querySelector('m-t')).color,
                        mode:doc.defaultView.getComputedStyle(doc.documentElement).colorScheme,
                        inert:sheet.inert, hidden:sheet.getAttribute('aria-hidden'),
                        index:paginator.displayedIndex, commits:commits.length, relocations:relocations.length};
                }""", {'scheme': scheme, 'light': light, 'dark': dark})
                self.assertEqual(result['preview'], color)
                self.assertEqual(result['live'], color)
                self.assertEqual(result['mode'], scheme)
                self.assertTrue(result['inert'])
                self.assertEqual(result['hidden'], 'true')
                self.assertEqual((result['index'], result['commits'], result['relocations']), (0, 0, 0))
                page.evaluate('turn.cancel()')
                previous_color = color

    def test_trusted_margin_drags_turn_both_directions_without_covering_controls(self):
        for rtl in [False, True]:
            for edge, y in [('top', 12), ('bottom', 832)]:
                with self.subTest(rtl=rtl, edge=edge):
                    page = self.open_reader(rtl)
                    self.set_inset_reader_layout(page)
                    page.evaluate('setEbookViewerPageTurnStyle("slide")')
                    for direction, index in [(1, 1), (-1, 0)]:
                        start, end = (60, 340) if rtl == (direction == 1) else (330, 50)
                        hit = page.evaluate("""({x,y}) => {
                            const hit=document.elementFromPoint(x,y);
                            return {reader:hit===reader.view,tag:hit?.localName,id:hit?.id};
                        }""", {'x': start, 'y': y})
                        self.assertTrue(hit['reader'], f'The full-window page margin must receive input: {hit}')
                        page.mouse.move(start, y)
                        page.mouse.down()
                        try:
                            page.mouse.move((start+end)/2, y, steps=3)
                            wait_for_reader(page, 'Math.abs(Number(paginator.dataset.turnProgress)) > .2', timeout=3000)
                            page.mouse.move(end, y, steps=3)
                        finally:
                            page.mouse.up()
                        wait_for_reader(page, f'paginator.displayedIndex === {index} && !paginator.pageTurnPreviewActive')
                    self.assertEqual(page.evaluate('commits'), [1, 0])
                    # Native-like chrome remains above the full-window paper.
                    page.evaluate("""() => {
                        const button=document.createElement('button');
                        button.textContent='Fixture chrome';
                        Object.assign(button.style,{position:'fixed',top:'0',left:'145px',width:'100px',height:'26px',zIndex:'50'});
                        button.addEventListener('click',()=>window.fixtureChromeClicks=(window.fixtureChromeClicks??0)+1);
                        document.body.append(button);
                    }""")
                    page.get_by_role('button', name='Fixture chrome', exact=True).click()
                    self.assertEqual(page.evaluate('fixtureChromeClicks'), 1)
                    self.assertEqual(page.evaluate('commits'), [1, 0])

    def test_unclaimed_margin_press_released_on_chrome_does_not_block_next_turn(self):
        page = self.open_reader()
        self.set_inset_reader_layout(page)
        page.evaluate("""() => {
            setEbookViewerPageTurnStyle('slide');
            const button=document.createElement('button');
            button.textContent='Fixture next';
            Object.assign(button.style,{position:'fixed',top:'0',left:'340px',width:'50px',height:'26px',zIndex:'50'});
            window.fixtureNextResult=null;
            button.onclick=()=>{
                fixtureNextResult='pending';
                paginator.next(undefined,{allowBookEndcap:false}).then(result=>fixtureNextResult=result);
            };
            document.body.append(button);
        }""")
        self.assertTrue(page.evaluate('document.elementFromPoint(338,12)===reader.view'))
        page.mouse.move(338, 12)
        page.mouse.down()
        try:
            # Cross into chrome without claiming the eight-pixel drag slop.
            page.mouse.move(342, 12)
        finally:
            page.mouse.up()
        self.assertFalse(page.evaluate('paginator.pageTurnPreviewActive'))
        page.get_by_role('button', name='Fixture next', exact=True).click()
        wait_for_reader(page, 'fixtureNextResult!==null && fixtureNextResult!=="pending"')
        self.assertTrue(page.evaluate('fixtureNextResult===true'), page.evaluate('fixtureNextResult'))
        self.assertEqual(page.evaluate('paginator.displayedIndex'), 1)
        self.assertEqual(page.evaluate('commits'), [1])

    def test_preview_geometry_and_cancel_keep_committed_state(self):
        for rtl in [False, True]:
            with self.subTest(rtl=rtl):
                page = self.open_reader(rtl)
                self.prepare(page)
                width = page.evaluate('paginator.getBoundingClientRect().width')
                self.assertEqual(page.evaluate("""() => {
                    turn.update(0);
                    return getComputedStyle(paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet')).visibility;
                }"""), 'hidden')
                for progress in [.25, .5, .75]:
                    pose = page.evaluate("""progress => {
                        turn.update(progress);
                        const root = paginatorRoots.get(paginator);
                        const sheet = root.querySelector('.mnb-slide-sheet');
                        const top = root.querySelector('#top:not(.mnb-slide-sheet)');
                        return {current:new DOMMatrix(getComputedStyle(top).transform).m41,
                            neighbor:new DOMMatrix(getComputedStyle(sheet).transform).m41,
                            shade:Number(getComputedStyle(sheet.querySelector('.mnb-slide-shade')).opacity),
                            inert:sheet.inert, index:paginator.displayedIndex,
                            sameDocument:paginator.getContents()[0].doc === originalDocument,
                            relocations:relocations.length, commits:commits.length,
                            frameCount:root.querySelectorAll('iframe').length,
                            sandbox:sheet.querySelector('iframe').getAttribute('sandbox')};
                    }""", progress)
                    sign = 1 if rtl else -1
                    self.assertAlmostEqual(pose['current'], sign * width * progress, delta=.1)
                    self.assertAlmostEqual(pose['neighbor'], -sign * width * .15 * (1-progress), delta=.1)
                    self.assertAlmostEqual(pose['shade'], .24 * (1-progress), delta=.001)
                    self.assertTrue(pose['inert'])
                    self.assertEqual(pose['sandbox'], 'allow-same-origin')
                    self.assertTrue(pose['sameDocument'])
                    self.assertEqual(pose['index'], 0)
                    self.assertEqual(pose['relocations'], 0)
                    self.assertEqual(pose['commits'], 0)
                    self.assertEqual(pose['frameCount'], 2)
                page.evaluate('turn.cancel()')
                self.assertEqual(page.evaluate('paginatorRoots.get(paginator).querySelectorAll("iframe").length'), 2)
                self.assertFalse(page.evaluate('paginator.pageTurnPreviewActive'))
                self.assertEqual(page.evaluate('paginatorRoots.get(paginator).querySelector(".mnb-slide-sheet").style.visibility'), 'hidden')
                self.assertEqual(page.evaluate('relocations.length'), 0)
                self.assertTrue(page.evaluate('paginator.getContents()[0].doc === originalDocument'))

    def test_preview_reuses_one_inert_surface_and_retires_stale_visuals(self):
        page = self.open_reader()
        self.prepare(page)
        page.evaluate("""() => {
            window.firstPreview = paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe').contentDocument;
            turn.cancel();
        }""")
        self.prepare(page)
        self.assertTrue(page.evaluate('paginatorRoots.get(paginator).querySelector(".mnb-slide-sheet iframe").contentDocument === firstPreview'))
        self.assertEqual(page.evaluate("""async () => {
            document.body.dataset.mnbColorScheme='dark';
            document.documentElement.style.setProperty('color-scheme','dark');
            document.body.style.setProperty('color-scheme','dark');
            await new Promise(requestAnimationFrame);
            return firstPreview.defaultView.getComputedStyle(firstPreview.documentElement).colorScheme;
        }"""), 'dark')
        page.evaluate("""() => {
            turn.cancel();
            originalDocument.body.classList.add('changed-visual-cache');
        }""")
        self.prepare(page)
        self.assertFalse(page.evaluate('paginatorRoots.get(paginator).querySelector(".mnb-slide-sheet iframe").contentDocument === firstPreview'))
        self.assertEqual(page.evaluate('paginatorRoots.get(paginator).querySelectorAll("iframe").length'), 2)
        page.evaluate('turn.cancel(); setEbookViewerPageTurnStyle("instant")')
        self.assertEqual(page.evaluate('paginatorRoots.get(paginator).querySelectorAll("iframe").length'), 1)
        self.assertEqual(page.evaluate('commits.length + relocations.length'), 0)

    def test_incoming_preview_matches_committed_text_geometry(self):
        scenarios = [
            ('application/xhtml+xml', '', None),
            ('text/html', '<!doctype html>', None),
            ('text/html', '', None),
            ('application/xhtml+xml', '', {'readerFontSize': 24, 'readerBoldText': True, 'colorScheme': 'dark'}),
        ]
        for media_type, doctype, presentation in scenarios:
            with self.subTest(media_type=media_type, doctype=doctype, presentation=presentation):
                page = self.open_reader(presentation=presentation)
                page.evaluate("""async ({mediaType,doctype}) => {
                    const section=paginator.sections[1];
                    const src=await section.load();
                    const html=await (await fetch(src)).text();
                    section.unload();
                    window.geometryFixtureURL=URL.createObjectURL(new Blob([
                        doctype+html.replace(/<!doctype[^>]*>/i,'')
                    ],{type:mediaType}));
                    section.load=async()=>geometryFixtureURL;
                    section.unload=()=>{};
                }""", {'mediaType': media_type, 'doctype': doctype})
                self.prepare(page)
                result = page.evaluate("""async () => {
                    const root=paginatorRoots.get(paginator);
                    const measure=iframe => {
                        const doc=iframe.contentDocument, text=doc.querySelector('m-t').firstChild;
                        const range=doc.createRange(); range.setStart(text,0); range.setEnd(text,1);
                        const glyph=range.getBoundingClientRect(), frame=iframe.getBoundingClientRect();
                        const style=doc.defaultView.getComputedStyle(text.parentElement);
                        return {mode:doc.compatMode,x:frame.x+glyph.x,y:frame.y+glyph.y,
                            width:glyph.width,height:glyph.height,
                            font:style.font,lineHeight:style.lineHeight};
                    };
                    turn.update(1);
                    await new Promise(requestAnimationFrame);
                    const preview=measure(root.querySelector('.mnb-slide-sheet iframe'));
                    const moved=await turn.commit({allowBookEndcap:false});
                    await new Promise(requestAnimationFrame);
                    const committed=measure(paginator.getContents()[0].iframe);
                    return {preview,committed,moved};
                }""")
                page.evaluate('paginator.destroy(); URL.revokeObjectURL(geometryFixtureURL)')
                self.assertTrue(result['moved'])
                self.assertEqual(result['preview']['mode'], result['committed']['mode'])
                for key in ['x', 'y', 'width', 'height']:
                    self.assertAlmostEqual(result['preview'][key], result['committed'][key], delta=.5,
                                           msg=f'Incoming text must not jump at commit ({key}): {result}')

    def test_preview_scripts_and_inline_handlers_never_execute(self):
        page = self.open_reader()
        page.evaluate("""async () => {
            const section = paginator.sections[1];
            const src = await section.load();
            const html = await (await fetch(src)).text();
            section.unload();
            const hostile = html.replace('</head>', '<script>parent.previewScriptExecuted=true</script></head>')
                .replace('<body ', '<body onload="parent.previewHandlerExecuted=true" ');
            window.hostileURL = URL.createObjectURL(new Blob([hostile], {type:'text/html'}));
            section.load = async () => hostileURL;
            section.unload = () => {};
        }""")
        self.prepare(page)
        page.evaluate("""() => {
            const doc = paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe').contentDocument;
            doc.body.dispatchEvent(new Event('load'));
            turn.cancel();
        }""")
        self.assertFalse(page.evaluate('!!window.previewScriptExecuted || !!window.previewHandlerExecuted'))
        page.evaluate('paginator.destroy(); URL.revokeObjectURL(hostileURL)')

    def test_source_mutation_during_preparation_is_not_cached_for_the_next_drag(self):
        page = self.open_long_reader()
        result = page.evaluate("""async () => {
            const paginator=view.renderer;
            paginator.setPageTurnStyle('slide');
            const original=paginator.getContents()[0].doc;
            original.body.dataset.slideVisualState='before';
            const root=paginatorRoots.get(paginator);
            const mutation=new MutationObserver(() => {
                if (!root.querySelector('.mnb-slide-sheet iframe')) return;
                mutation.disconnect();
                // The snapshot was imported before its first rendering frame.
                original.body.dataset.slideVisualState='after';
            });
            mutation.observe(root,{childList:true,subtree:true});
            const first=await paginator.preparePageTurn(1);
            const firstDoc=root.querySelector('.mnb-slide-sheet iframe').contentDocument;
            const firstValue=firstDoc.body.dataset.slideVisualState;
            first.cancel();
            const next=await paginator.preparePageTurn(1);
            const nextDoc=root.querySelector('.mnb-slide-sheet iframe').contentDocument;
            const result={firstValue,nextValue:nextDoc.body.dataset.slideVisualState,
                reused:firstDoc===nextDoc,sameDocument:paginator.getContents()[0].doc===original};
            next.cancel();
            return result;
        }""")
        self.assertEqual(result['firstValue'], 'before')
        self.assertEqual(result['nextValue'], 'after')
        self.assertFalse(result['reused'])
        self.assertTrue(result['sameDocument'])

    def test_content_selection_and_link_taps_keep_native_browser_behavior(self):
        page = self.open_reader()
        page.evaluate("""() => {
            setEbookViewerPageTurnStyle('slide');
            const doc = originalDocument;
            const text = doc.createTextNode('Selected text');
            doc.body.append(text);
            const range = doc.createRange(); range.selectNodeContents(text);
            doc.getSelection().addRange(range);
            pointer('pointerdown',350); pointer('pointermove',50); pointer('pointerup',50);
        }""")
        self.assertFalse(page.evaluate('paginator.pageTurnPreviewActive'))
        self.assertEqual(page.evaluate('commits.length'), 0)
        page.evaluate("""() => {
            const doc = originalDocument;
            doc.getSelection().removeAllRanges();
            const link = doc.createElement('a'); link.textContent = 'Fixture link'; link.href = '#fixture';
            Object.assign(link.style, {position:'fixed',left:'50px',top:'100px',zIndex:'99999'});
            link.addEventListener('click', event => { window.fixtureLinkClicks = (window.fixtureLinkClicks ?? 0) + 1; event.preventDefault(); });
            doc.body.append(link);
        }""")
        # A trusted browser click reaches the EPUB's normal link handling.
        document_url = page.evaluate('originalDocument.URL')
        content_frame = next(frame for frame in page.frames if frame.url == document_url)
        content_frame.get_by_text('Fixture link', exact=True).click()
        self.assertEqual(page.evaluate('fixtureLinkClicks'), 1)
        self.assertFalse(page.evaluate('paginator.pageTurnPreviewActive'))
        self.assertEqual(page.evaluate('commits.length'), 0)

    def test_lookup_boundary_turn_with_selection_moves_once_and_keeps_preparation_inert(self):
        page = self.open_reader()
        page.evaluate("""() => {
            setEbookViewerPageTurnStyle('slide');
            window.selectFixtureText = () => {
                const doc=paginator.getContents()[0].doc;
                const range=doc.createRange();
                range.selectNodeContents(doc.querySelector('m-t'));
                doc.getSelection().removeAllRanges();
                doc.getSelection().addRange(range);
                return doc.getSelection().toString();
            };
            window.selectedDuringPreparation=[];
            paginator.addEventListener('pageturnpreviewload', () => {
                selectedDuringPreparation.push(paginator.getContents()[0].doc.getSelection().toString());
            });
        }""")
        for direction, index in [('next', 1), ('previous', 0)]:
            with self.subTest(direction=direction):
                selected = page.evaluate('selectFixtureText()')
                self.assertTrue(selected)
                result = page.evaluate("""async direction => {
                    commits=[]; relocations=[]; selectedDuringPreparation=[];
                    const receipt=await reader.performLookupNavigationPageTurn({
                        kind:'word', direction, navigationToken:'selected-boundary-'+direction,
                    });
                    return {receipt,index:paginator.displayedIndex,commits,selectedDuringPreparation,
                        active:paginator.pageTurnPreviewActive};
                }""", direction)
                self.assertTrue(result['receipt']['moved'], result)
                self.assertFalse(result['receipt']['opened'])
                self.assertEqual(result['receipt']['movementDisposition'], 'moved')
                self.assertEqual(result['index'], index)
                self.assertEqual(result['commits'], [index])
                self.assertEqual(result['selectedDuringPreparation'], [selected])
                self.assertFalse(result['active'])

    def test_terminal_lookup_boundary_keeps_selection_and_reports_no_movement(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const doc=paginator.getContents()[0].doc;
            const range=doc.createRange(); range.selectNodeContents(doc.querySelector('m-t'));
            doc.getSelection().addRange(range);
            const selected=doc.getSelection().toString();
            const receipt=await reader.performLookupNavigationPageTurn({
                kind:'word', direction:'previous', navigationToken:'selected-terminal',
            });
            return {receipt,selected,after:doc.getSelection().toString(),
                sameDocument:paginator.getContents()[0].doc===doc,
                active:paginator.pageTurnPreviewActive,index:paginator.displayedIndex,commits,relocations};
        }""")
        self.assertTrue(result['selected'])
        self.assertEqual(result['after'], result['selected'])
        self.assertEqual(result['receipt']['movementDisposition'], 'no-move', result)
        self.assertFalse(result['receipt']['moved'])
        self.assertFalse(result['receipt']['opened'])
        self.assertTrue(result['sameDocument'])
        self.assertFalse(result['active'])
        self.assertEqual((result['index'], result['commits'], result['relocations']), (0, [], []))

    def test_large_chapter_uses_one_instant_turn_without_allocating_a_preview(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section = paginator.sections[1];
            const src = await section.load();
            const html = await (await fetch(src)).text();
            section.unload();
            const large = html.replace('</body>', '<div hidden>' + '<span></span>'.repeat(21000) + '</div></body>');
            const url = URL.createObjectURL(new Blob([large], {type:'text/html'}));
            section.load = async () => url;
            section.unload = () => {};
            try {
                const turn = await paginator.preparePageTurn(1);
                const before = {painted:paginator.hasAttribute('data-turn-progress'),
                    frames:paginatorRoots.get(paginator).querySelectorAll('iframe').length,
                    sameDocument:paginator.getContents()[0].doc===originalDocument};
                const moved = await turn.commit({allowBookEndcap:false});
                return {before,moved,index:paginator.displayedIndex,commits,
                    frames:paginatorRoots.get(paginator).querySelectorAll('iframe').length};
            } finally { paginator.destroy(); URL.revokeObjectURL(url); }
        }""")
        self.assertEqual(result['before'], {'painted': False, 'frames': 1, 'sameDocument': True})
        self.assertTrue(result['moved'])
        self.assertEqual(result['index'], 1)
        self.assertEqual(result['commits'], [1])
        self.assertEqual(result['frames'], 1)

    def test_renderer_capabilities_match_reflowable_and_fixed_layout(self):
        page = self.open_reader()
        self.assertEqual(page.evaluate('paginator.supportedPageTurnStyles'), ['instant', 'slide'])
        self.assertEqual(page.evaluate("""async () => {
            await import('./fixed-layout.js');
            return document.createElement('foliate-fxl').supportedPageTurnStyles;
        }"""), ['instant'])
        self.assertTrue(page.evaluate('nativeMessages.some(x => x.name === "ebookViewerLoaded" && x.payload.pageTurnStyles?.includes("slide"))'))

    def test_scrolled_initial_layout_declines_slide_paint_and_input(self):
        page = self.open_reader(layout='scrolled', page_turn='slide')
        result = page.evaluate("""() => {
            pointer('pointerdown',350); pointer('pointermove',50); pointer('pointerup',50);
            return {styles:paginator.supportedPageTurnStyles,style:paginator.getAttribute('page-turn'),
                expanded:reader.view.hasAttribute('data-slide-pages'),active:paginator.pageTurnPreviewActive,
                touchAction:originalDocument.documentElement.style.touchAction,commits};
        }""")
        self.assertEqual(result['styles'], ['instant'])
        self.assertEqual(result['style'], 'instant')
        self.assertFalse(result['expanded'])
        self.assertFalse(result['active'])
        self.assertEqual(result['touchAction'], '')
        self.assertEqual(result['commits'], [])

    def test_renderer_lifecycle_resets_effective_slide_style(self):
        page = self.open_reader()
        result = page.evaluate("""() => {
            const renderer=document.createElement('foliate-paginator');
            document.body.append(renderer);
            try {
                renderer.open({dir:'ltr',sections:[]});
                renderer.setPageTurnStyle('slide');
                const enabled=renderer.getAttribute('page-turn');
                renderer.open({dir:'ltr',sections:[]});
                const reopened=renderer.getAttribute('page-turn');
                renderer.setPageTurnStyle('instant');
                const instant=renderer.getAttribute('page-turn');
                renderer.setPageTurnStyle('slide');
                renderer.destroy();
                return {enabled,reopened,instant,destroyed:renderer.getAttribute('page-turn')};
            } finally { renderer.destroy(); renderer.remove(); }
        }""")
        self.assertEqual(result, {'enabled':'slide','reopened':'instant','instant':'instant','destroyed':'instant'})

    def test_chapter_commit_uses_existing_document_and_relocation_boundaries(self):
        page = self.open_reader()
        self.prepare(page)
        self.assertTrue(page.evaluate('async () => { turn.update(1); return await turn.commit({allowBookEndcap:false}); }'))
        self.assertEqual(page.evaluate('paginator.displayedIndex'), 1)
        self.assertEqual(page.evaluate('commits'), [1])
        self.assertTrue(page.evaluate('relocations.length > 0 && relocations.every(x => x.index === 1)'))
        self.assertFalse(page.evaluate('paginator.getContents()[0].doc === originalDocument'))
        self.assertEqual(page.evaluate('paginatorRoots.get(paginator).querySelectorAll("iframe").length'), 1)
        self.assertEqual(page.evaluate('nativeMessages.filter(x=>x.name === "markSectionAsRead").length'), 0)
        # The backward sheet covers the current page with the inverse shade.
        page.evaluate('originalDocument = paginator.getContents()[0].doc; relocations=[]; commits=[];')
        self.prepare(page, -1)
        pose = page.evaluate("""() => {
            turn.update(.5); const root=paginatorRoots.get(paginator);
            return {shade:Number(getComputedStyle(root.querySelector('#top:not(.mnb-slide-sheet) > .mnb-slide-shade')).opacity),
                previousOnTop:Number(root.querySelector('.mnb-slide-sheet').style.zIndex)};
        }""")
        self.assertAlmostEqual(pose['shade'], .12, delta=.001)
        self.assertEqual(pose['previousOnTop'], 2)
        page.evaluate('turn.cancel()')
        self.assertEqual(page.evaluate('paginator.displayedIndex'), 1)
        self.assertEqual(page.evaluate('relocations.length'), 0)

    def test_catching_settle_and_reversing_cancels_without_navigation(self):
        page = self.open_reader()
        page.evaluate('setEbookViewerPageTurnStyle("slide"); pointer("pointerdown",350); pointer("pointermove",50);')
        wait_for_reader(page, 'Number(paginator.dataset.turnProgress) > .7')
        page.evaluate("""() => {
            // Catch the admitted settle in the same input task. Polling a narrow
            // animation interval can miss it when a busy WebKit skips frames.
            pointer('pointerup',50);
            const held=Number(paginator.dataset.turnProgress);
            pointer('pointerdown',50);
            pointer('pointermove',50+held*paginator.getBoundingClientRect().width-40);
            pointer('pointerup',50+held*paginator.getBoundingClientRect().width-40);
        }""")
        wait_for_reader(page, '!paginator.hasAttribute("data-turn-progress")')
        self.assertEqual(page.evaluate('paginator.displayedIndex'), 0)
        self.assertEqual(page.evaluate('relocations.length'), 0)
        self.assertEqual(page.evaluate('commits.length'), 0)

    def test_finished_drag_commits_once(self):
        page = self.open_reader()
        page.evaluate('setEbookViewerPageTurnStyle("slide"); pointer("pointerdown",350); pointer("pointermove",50);')
        wait_for_reader(page, 'Number(paginator.dataset.turnProgress) > .7')
        page.evaluate('pointer("pointerup",50)')
        wait_for_reader(page, 'paginator.displayedIndex === 1 && !paginator.pageTurnPreviewActive')
        self.assertEqual(page.evaluate('commits'), [1])
        self.assertEqual(page.evaluate('paginatorRoots.get(paginator).querySelectorAll("iframe").length'), 1)

    def test_native_pointer_capture_loss_and_cancellation_release_drag(self):
        for interruption in ['lost', 'blur', 'instant']:
            with self.subTest(interruption=interruption):
                page = self.open_reader()
                self.set_inset_reader_layout(page)
                page.evaluate("""() => {
                    setEbookViewerPageTurnStyle('slide');
                    paginator.addEventListener('gotpointercapture', e => window.capturedPointer=e.pointerId);
                }""")
                page.mouse.move(330, 12)
                page.mouse.down()
                try:
                    page.mouse.move(220, 12, steps=3)
                    wait_for_reader(page, 'globalThis.capturedPointer !== undefined && Number(paginator.dataset.turnProgress) > .2')
                    if interruption == 'lost':
                        page.evaluate('paginator.releasePointerCapture(capturedPointer)')
                    elif interruption == 'blur':
                        page.evaluate('dispatchEvent(new Event("blur"))')
                    else:
                        page.evaluate('setEbookViewerPageTurnStyle("instant")')
                    self.assertFalse(page.evaluate('paginator.hasPointerCapture(capturedPointer)'), 'Cancelled drag must release capture')
                    page.mouse.move(200, 12)
                    wait_for_reader(page, '!paginator.pageTurnPreviewActive', timeout=3000)
                finally:
                    page.mouse.up()
                self.assertEqual(page.evaluate('commits'), [])
                page.evaluate('setEbookViewerPageTurnStyle("slide")')
                page.mouse.move(330, 12)
                page.mouse.down()
                try:
                    page.mouse.move(220, 12, steps=3)
                    wait_for_reader(page, 'Number(paginator.dataset.turnProgress) > .2')
                    page.mouse.move(50, 12, steps=3)
                finally:
                    page.mouse.up()
                wait_for_reader(page, 'paginator.displayedIndex === 1 && !paginator.pageTurnPreviewActive')
                self.assertEqual(page.evaluate('commits'), [1])

    def test_trusted_touch_drag_in_content_commits_once(self):
        if os.environ.get('PAGE_TURN_BROWSER', 'chromium') != 'chromium':
            self.skipTest('Trusted touch injection uses the Chromium input protocol')
        for y in [12, 400, 832]:
            with self.subTest(y=y):
                page = self.open_reader()
                self.set_inset_reader_layout(page)
                page.evaluate('setEbookViewerPageTurnStyle("slide")')
                session = page.context.new_cdp_session(page)
                try:
                    session.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': 330, 'y': y}]})
                    session.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': 220, 'y': y}]})
                    wait_for_reader(page, 'Number(paginator.dataset.turnProgress) > .2')
                    session.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': 50, 'y': y}]})
                    wait_for_reader(page, 'Number(paginator.dataset.turnProgress) > .65')
                    session.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
                    wait_for_reader(page, 'paginator.displayedIndex === 1 && !paginator.pageTurnPreviewActive')
                    self.assertEqual(page.evaluate('commits'), [1])
                finally:
                    session.detach()

    def test_trusted_touch_reversal_across_origin_keeps_capture_and_moves_one_page(self):
        if os.environ.get('PAGE_TURN_BROWSER', 'chromium') != 'chromium':
            self.skipTest('Trusted touch injection uses the Chromium input protocol')
        for vertical in [False, True]:
            with self.subTest(vertical=vertical):
                page = self.open_long_reader(vertical)
                before = page.evaluate("""async () => {
                    window.paginator=view.renderer;
                    await paginator.goTo({index:0,anchor:()=>.5});
                    paginator.setPageTurnStyle('slide');
                    window.originalDocument=paginator.getContents()[0].doc;
                    window.turnRelocations=[];
                    paginator.addEventListener('relocate',e=>turnRelocations.push(e.detail));
                    originalDocument.addEventListener('gotpointercapture',e=>{
                        window.captureTarget=e.target; window.captureID=e.pointerId;
                    });
                    return await paginator.pageMetrics();
                }""")
                self.assertGreater(before['page'], 1)
                self.assertLess(before['page'], before['pages'] - 2)
                # In vertical books the physical forward gesture is mirrored.
                start, forward, reverse = (290, 350, 40) if vertical else (100, 40, 350)
                session = page.context.new_cdp_session(page)
                try:
                    session.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [{'x': start, 'y': 400}]})
                    session.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': forward, 'y': 400}]})
                    wait_for_reader(page, 'Number(paginator.dataset.turnProgress) > .1')
                    session.send('Input.dispatchTouchEvent', {'type': 'touchMove', 'touchPoints': [{'x': reverse, 'y': 400}]})
                    wait_for_reader(page, 'Number(paginator.dataset.turnProgress) < -.6')
                    self.assertTrue(page.evaluate('captureTarget.hasPointerCapture(captureID)'))
                    self.assertEqual(page.evaluate('turnRelocations.length'), 0)
                    session.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
                    wait_for_reader(page, '!paginator.pageTurnPreviewActive')
                    after = page.evaluate("""async () => ({
                        metrics:await paginator.pageMetrics(),
                        sameDocument:paginator.getContents()[0].doc===originalDocument,
                        captured:captureTarget.hasPointerCapture(captureID),
                        relocations:turnRelocations.map(({reason,index})=>({reason,index})),
                    })""")
                    self.assertEqual(len(after['relocations']), 1, after)
                    self.assertEqual(after['metrics']['page'], before['page'] - 1)
                    self.assertTrue(after['sameDocument'])
                    self.assertFalse(after['captured'])
                finally:
                    session.detach()

    def test_reflow_retires_preview(self):
        page = self.open_reader()
        self.prepare(page)
        page.evaluate('turn.update(.6)')
        page.set_viewport_size({'width': 430, 'height': 844})
        wait_for_reader(page, '!paginator.hasAttribute("data-turn-progress")')
        self.assertFalse(page.evaluate('turn.commit()'))
        self.assertEqual(page.evaluate('paginator.displayedIndex'), 0)

    def test_setting_change_retires_preview(self):
        page = self.open_reader()
        self.prepare(page)
        page.evaluate('turn.update(.6); setEbookViewerPageTurnStyle("instant")')
        self.assertFalse(page.evaluate('turn.commit()'))
        self.assertEqual(page.evaluate('paginator.getAttribute("page-turn")'), 'instant')
        self.assertEqual(page.evaluate('paginatorRoots.get(paginator).querySelectorAll("iframe").length'), 1)

    def test_destroy_releases_a_late_neighbor_without_publishing(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            const load=section.load.bind(section), unload=section.unload.bind(section);
            let release, loads=0, unloads=0;
            section.load=async () => { const src=await load(); loads++; await new Promise(r=>release=r); return src; };
            section.unload=() => { unloads++; return unload(); };
            const pending=paginator.preparePageTurn(1);
            while (!release) await new Promise(requestAnimationFrame);
            paginator.destroy(); release();
            const result=await pending;
            return {result,loads,unloads,commits:commits.length,relocations:relocations.length};
        }""")
        self.assertIsNone(result['result'])
        self.assertEqual(result['loads'], 1)
        self.assertEqual(result['unloads'], 1)
        self.assertEqual(result['commits'], 0)
        self.assertEqual(result['relocations'], 0)

    def test_timed_out_neighbor_releases_late_reference_without_cancelling_new_turn(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            const load=section.load.bind(section), unload=section.unload.bind(section);
            let release, loads=0, unloads=0;
            section.load=async () => { const src=await load(); loads++; await new Promise(r=>release=r); return src; };
            section.unload=() => { unloads++; return unload(); };
            const obsolete=await paginator.preparePageTurn(1);
            const replacement=await paginator.preparePageTurn(-1);
            release();
            await new Promise(requestAnimationFrame);
            const result={instant:obsolete.instant,loads,unloads,
                moved:await obsolete.commit({allowBookEndcap:false}),
                active:paginator.pageTurnPreviewActive,index:paginator.displayedIndex,commits};
            replacement.cancel();
            return result;
        }""")
        self.assertTrue(result['instant'])
        self.assertEqual(result['loads'], 1)
        self.assertEqual(result['unloads'], 1)
        self.assertFalse(result['moved'])
        self.assertTrue(result['active'])
        self.assertEqual(result['index'], 0)
        self.assertEqual(result['commits'], [])

    def test_cancel_after_neighbor_load_resolves_releases_its_reference(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            const load=section.load.bind(section), unload=section.unload.bind(section);
            let release, loads=0, unloads=0;
            section.load=() => new Promise(resolve => {
                load().then(src => {
                    loads++;
                    release=() => resolve(src);
                });
            });
            section.unload=() => { unloads++; return unload(); };
            const pending=paginator.preparePageTurn(1);
            while (!release) await new Promise(requestAnimationFrame);
            // Cancel after the load callback has acquired its reference but
            // before the async preparation resumes from Promise.race.
            release();
            queueMicrotask(() => paginator.cancelPageTurn());
            const turn=await pending;
            return {turn,loads,unloads,active:paginator.pageTurnPreviewActive,
                index:paginator.displayedIndex,commits,relocations};
        }""")
        self.assertIsNone(result['turn'])
        self.assertEqual(result['loads'], 1)
        self.assertEqual(result['unloads'], 1)
        self.assertFalse(result['active'])
        self.assertEqual(result['index'], 0)
        self.assertEqual(result['commits'], [])
        self.assertEqual(result['relocations'], [])

    def test_stalled_preview_stylesheet_falls_back_and_late_load_cannot_publish(self):
        page = self.open_reader()
        held_requests = []
        page.route('**/stalled-slide-preview.css', lambda route: held_requests.append(route))
        page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            window.normalSectionLoad=section.load;
            const src=await section.load();
            const html=await (await fetch(src)).text();
            section.unload();
            const withCSS=html.replace('</head>', '<link rel="stylesheet" href="'+location.origin+'/stalled-slide-preview.css"></head>');
            window.stalledPreviewURL=URL.createObjectURL(new Blob([withCSS],{type:'text/html'}));
            section.load=async()=>stalledPreviewURL;
            // The injected URL is test-owned, not a section resource reference.
            window.normalSectionUnload=section.unload;
            section.unload=()=>{};
            window.turn=await paginator.preparePageTurn(1);
            section.load=normalSectionLoad; section.unload=normalSectionUnload;
        }""")
        self.assertTrue(held_requests, 'Expected the actual preview stylesheet request to stall')
        self.assertTrue(page.evaluate('turn.instant && !paginator.pageTurnPreviewActive'))
        for route in held_requests:
            route.fulfill(status=200, content_type='text/css', body='body { color: red; }')
        result = page.evaluate("""async () => {
            await new Promise(requestAnimationFrame);
            const moved=await turn.commit({allowBookEndcap:false});
            URL.revokeObjectURL(stalledPreviewURL);
            return {moved,index:paginator.displayedIndex,commits,
                frames:paginatorRoots.get(paginator).querySelectorAll('iframe').length};
        }""")
        self.assertTrue(result['moved'])
        self.assertEqual(result['index'], 1)
        self.assertEqual(result['commits'], [1])
        self.assertEqual(result['frames'], 1)

    def test_stalled_inline_import_falls_back_without_publishing_an_unstyled_preview(self):
        page = self.open_reader()
        held_requests = []
        page.route('**/inline-preview.css', lambda route: held_requests.append(route))
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            const src=await section.load();
            const html=await (await fetch(src)).text();
            section.unload();
            const style='<style>@import url("'+location.origin+'/inline-preview.css");</style>';
            const url=URL.createObjectURL(new Blob([html.replace('</head>',style+'</head>')],{type:'text/html'}));
            const load=section.load, unload=section.unload;
            section.load=async()=>url; section.unload=()=>{};
            let hooks=0;
            const hook=()=>hooks++;
            paginator.addEventListener('pageturnpreviewload',hook);
            try {
                window.turn=await paginator.preparePageTurn(1);
                return {instant:turn.instant===true,active:paginator.pageTurnPreviewActive,hooks,
                    index:paginator.displayedIndex,commits:commits.length};
            } finally {
                paginator.removeEventListener('pageturnpreviewload',hook);
                section.load=load; section.unload=unload;
                URL.revokeObjectURL(url);
            }
        }""")
        self.assertTrue(held_requests, 'Expected the inline stylesheet import request to stall')
        for route in held_requests:
            route.fulfill(status=200, content_type='text/css', body='body { font-size: 40px !important; }')
        self.assertEqual(result, {'instant': True, 'active': False, 'hooks': 0, 'index': 0, 'commits': 0})
        self.assertTrue(page.evaluate('turn.commit({allowBookEndcap:false})'))
        self.assertEqual(page.evaluate('commits'), [1])

    def test_inline_import_is_ready_before_preview_paint_hooks(self):
        page = self.open_reader()
        held_requests = []
        released = False
        css = ':root { --fixture-import-ready: loaded; }'

        def serve_import(route):
            if released:
                # Direction measurement can load the same publication CSS in
                # a separate document. Only the initial readiness is held.
                route.fulfill(status=200, content_type='text/css', body=css)
            else:
                held_requests.append(route)

        page.route('**/loaded-inline-preview.css', serve_import)
        page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            const src=await section.load();
            const html=await (await fetch(src)).text();
            section.unload();
            const style='<style>@import url("'+location.origin+'/loaded-inline-preview.css");</style>';
            window.inlinePreviewURL=URL.createObjectURL(new Blob([html.replace('</head>',style+'</head>')],{type:'text/html'}));
            section.load=async()=>inlinePreviewURL; section.unload=()=>{};
            window.importPaint=null;
            paginator.addEventListener('pageturnpreviewload', ({detail:{doc}}) => {
                importPaint=getComputedStyle(doc.documentElement).getPropertyValue('--fixture-import-ready').trim();
            });
            window.inlineTurn=null;
            window.inlinePreparation=paginator.preparePageTurn(1).then(turn=>inlineTurn=turn);
        }""")
        wait_for_reader(page, 'paginatorRoots.get(paginator).querySelector(".mnb-slide-sheet iframe")?.contentDocument?.querySelector("style")')
        before_import = page.evaluate('importPaint')
        released = True
        for route in held_requests:
            route.fulfill(status=200, content_type='text/css', body=css)
        result = page.evaluate("""async () => {
            const turn=await inlinePreparation;
            const result={paint:importPaint,instant:turn.instant===true};
            turn.cancel(); paginator.destroy(); URL.revokeObjectURL(inlinePreviewURL);
            return result;
        }""")
        self.assertTrue(held_requests, 'Expected the inline import request before releasing its response')
        self.assertIsNone(before_import, 'Paint hooks must wait for imported publication CSS')
        self.assertEqual(result, {'paint': 'loaded', 'instant': False})

    def test_paint_hook_cssom_import_waits_even_when_inline_text_is_unchanged(self):
        page = self.open_reader()
        held_requests = []
        page.route('**/hook-cssom-preview.css', lambda route: held_requests.append(route))
        page.evaluate("""async () => {
            const {preparePageTurnPreviewDocument}=await import('./page-turn-preview.js');
            const frame=document.createElement('iframe');
            frame.sandbox='allow-same-origin'; document.body.append(frame);
            window.cssomPreviewFrame=frame;
            const source=new DOMParser().parseFromString(
                '<!doctype html><html><head><style id="hook-style">:root { --hook-ready: before; }</style></head><body>Page</body></html>',
                'text/html');
            window.cssomPreviewReady=false;
            window.cssomPreviewPreparation=preparePageTurnPreviewDocument(
                frame.contentDocument,source,location.href,()=>frame.isConnected,doc=>{
                    doc.getElementById('hook-style').sheet.insertRule(
                        '@import url("'+location.origin+'/hook-cssom-preview.css");',0);
                }).then(ready=>cssomPreviewReady=ready);
        }""")
        wait_for_reader(page, 'cssomPreviewFrame.contentDocument.querySelector("style")?.sheet?.cssRules[0]?.type === CSSRule.IMPORT_RULE')
        page.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))')
        before = page.evaluate('cssomPreviewReady')
        for route in held_requests:
            route.fulfill(status=200, content_type='text/css', body=':root { --import-was-applied: yes; }')
        result = page.evaluate("""async () => {
            const ready=await cssomPreviewPreparation;
            const applied=getComputedStyle(cssomPreviewFrame.contentDocument.documentElement)
                .getPropertyValue('--import-was-applied').trim();
            cssomPreviewFrame.remove();
            return {ready,applied};
        }""")
        self.assertTrue(held_requests)
        self.assertFalse(before, 'A CSSOM import inserted by a paint hook is a new resource despite unchanged textContent')
        self.assertEqual(result, {'ready': True, 'applied': 'yes'})

    def test_conditional_import_waits_only_when_its_supports_condition_is_true(self):
        for condition, supported in [
            ('display: manabi-unavailable', False),
            ('display: block', True),
            ('selector(:is(*))', True),
            ('not (display: block)', False),
        ]:
            with self.subTest(condition=condition):
                page = self.open_reader()
                held_requests = []
                page.route('**/conditional-preview.css', lambda route: held_requests.append(route))
                result = page.evaluate("""async condition => {
                    setEbookViewerPageTurnStyle('slide');
                    const section=paginator.sections[1];
                    const src=await section.load();
                    const html=await (await fetch(src)).text();
                    section.unload();
                    const style='<style>@import url("'+location.origin+'/conditional-preview.css") supports('+condition+');</style>';
                    const url=URL.createObjectURL(new Blob([html.replace('</head>',style+'</head>')],{type:'text/html'}));
                    const load=section.load, unload=section.unload;
                    section.load=async()=>url; section.unload=()=>{};
                    let hooks=0;
                    const hook=()=>hooks++;
                    paginator.addEventListener('pageturnpreviewload',hook);
                    try {
                        const turn=await paginator.preparePageTurn(1);
                        const result={instant:turn.instant===true,active:paginator.pageTurnPreviewActive,hooks,
                            index:paginator.displayedIndex,commits:commits.length};
                        turn.cancel(); paginator.cancelPageTurn();
                        return result;
                    } finally {
                        paginator.removeEventListener('pageturnpreviewload',hook);
                        section.load=load; section.unload=unload;
                        URL.revokeObjectURL(url);
                    }
                }""", condition)
                for route in held_requests:
                    route.fulfill(status=200, content_type='text/css', body='body { font-size: 40px !important; }')
                self.assertEqual(result, {'instant': supported, 'active': not supported,
                                         'hooks': 0 if supported else 1, 'index': 0, 'commits': 0})
                if supported:
                    self.assertTrue(held_requests)

    def test_timed_out_direction_measurement_releases_its_hidden_iframe(self):
        page = self.open_reader()
        requests = []
        held_requests = []

        def serve_import(route):
            requests.append(route.request.url)
            if len(requests) == 1:
                route.fulfill(status=200, content_type='text/css', body='body { color: inherit; }')
            else:
                # Initial publication CSS is ready. Hold the copy requested by
                # Foliate's hidden writing-direction measurement document.
                held_requests.append(route)

        page.route('**/direction-measurement.css', serve_import)
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            const src=await section.load();
            const html=await (await fetch(src)).text(); section.unload();
            const style='<style>@import url("'+location.origin+'/direction-measurement.css");</style>';
            const url=URL.createObjectURL(new Blob([html.replace('</head>',style+'</head>')],{type:'text/html'}));
            const load=section.load,unload=section.unload;
            section.load=async()=>url; section.unload=()=>{};
            try { window.measurementTurn=await paginator.preparePageTurn(1); }
            finally { section.load=load;section.unload=unload;URL.revokeObjectURL(url); }
            await new Promise(requestAnimationFrame);
            return {instant:measurementTurn.instant===true,active:paginator.pageTurnPreviewActive,
                hiddenFrames:document.documentElement.querySelectorAll(':scope > iframe').length,
                index:paginator.displayedIndex,commits:commits.length};
        }""")
        for route in held_requests:
            route.fulfill(status=200, content_type='text/css', body='body { color: inherit; }')
        self.assertTrue(held_requests, 'Expected a stalled writing-direction measurement request')
        self.assertEqual(result, {'instant': True, 'active': False, 'hiddenFrames': 0, 'index': 0, 'commits': 0})
        self.assertTrue(page.evaluate('measurementTurn.commit({allowBookEndcap:false})'))
        self.assertEqual(page.evaluate('commits'), [1])

    def test_disabled_preview_stylesheet_does_not_force_an_instant_turn(self):
        page = self.open_reader()
        held_requests = []
        page.route('**/disabled-preview.css', lambda route: held_requests.append(route))
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            const src=await section.load();
            const html=await (await fetch(src)).text();
            section.unload();
            const withCSS=html.replace('</head>', '<link rel="stylesheet" disabled href="'+location.origin+'/disabled-preview.css"></head>');
            window.disabledPreviewURL=URL.createObjectURL(new Blob([withCSS],{type:'text/html'}));
            section.load=async()=>disabledPreviewURL;
            section.unload=()=>{};
            window.turn=await paginator.preparePageTurn(1);
            turn.update(.5);
            return {instant:turn.instant===true,painted:paginator.hasAttribute('data-turn-progress'),
                index:paginator.displayedIndex,commits,relocations};
        }""")
        for route in held_requests:
            route.fulfill(status=200, content_type='text/css', body='body { color: red; }')
        page.evaluate('turn.cancel(); paginator.destroy(); URL.revokeObjectURL(disabledPreviewURL)')
        self.assertFalse(result['instant'])
        self.assertTrue(result['painted'])
        self.assertEqual(result['index'], 0)
        self.assertEqual(result['commits'], [])
        self.assertEqual(result['relocations'], [])

    def test_empty_stylesheet_placeholders_do_not_force_instant_turn(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const section=paginator.sections[1];
            const src=await section.load();
            const html=await (await fetch(src)).text();
            section.unload();
            const placeholders='<link rel="stylesheet"><link rel="stylesheet" href=""><link rel="stylesheet" href="   ">'
                +'<style type="text/plain">Non-CSS publication placeholder</style>';
            const url=URL.createObjectURL(new Blob([html.replace('</head>',placeholders+'</head>')],{type:'text/html'}));
            section.load=async()=>url;
            section.unload=()=>{};
            try {
                const turn=await paginator.preparePageTurn(1);
                const instant=turn?.instant===true;
                turn?.update(.4);
                const previewDocument=paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe')?.contentDocument;
                const before={instant,painted:paginator.hasAttribute('data-turn-progress'),
                    placeholders:previewDocument?.querySelectorAll('link[rel="stylesheet"]').length??0,
                    index:paginator.displayedIndex,commits:commits.length};
                const moved=await turn.commit({allowBookEndcap:false});
                return {before,moved,index:paginator.displayedIndex,commits};
            } finally { URL.revokeObjectURL(url); }
        }""")
        self.assertFalse(result['before']['instant'])
        self.assertTrue(result['before']['painted'])
        self.assertGreaterEqual(result['before']['placeholders'], 3)
        self.assertEqual((result['before']['index'], result['before']['commits']), (0, 0))
        self.assertTrue(result['moved'])
        self.assertEqual(result['index'], 1)
        self.assertEqual(result['commits'], [1])

    def test_retargeted_reader_font_stylesheet_is_not_treated_as_already_loaded(self):
        page = self.open_reader()
        held_requests = []
        page.route('**/preview-old-font.css', lambda route: route.fulfill(status=200, content_type='text/css', body='body { color: black; }'))
        page.route('**/preview-new-font.css', lambda route: held_requests.append(route))
        result = page.evaluate("""async () => {
            const {copyCustomReaderFontStyleToDocument}=await import('./ebook-font-forwarding.js');
            const section=paginator.sections[1];
            const src=await section.load();
            const html=await (await fetch(src)).text();
            section.unload();
            const oldLink='<link id="mnb-custom-fonts-inline" rel="stylesheet" href="'+location.origin+'/preview-old-font.css">';
            const url=URL.createObjectURL(new Blob([html.replace('</head>',oldLink+'</head>')],{type:'text/html'}));
            const originalLoad=section.load, originalUnload=section.unload;
            section.load=async()=>url; section.unload=()=>{};
            const source=document.createElement('link');
            source.rel='stylesheet'; source.href=location.origin+'/preview-new-font.css';
            let retargeted=false, hookEntered=false;
            const errors=[];
            paginator.addEventListener('pageturnerror', e => errors.push(e.detail?.message));
            const forward=({detail:{doc}}) => {
                hookEntered=true;
                retargeted=copyCustomReaderFontStyleToDocument(source,doc,'preview-font-test');
            };
            paginator.addEventListener('pageturnpreviewload',forward);
            setEbookViewerPageTurnStyle('slide');
            try {
                window.turn=await paginator.preparePageTurn(1);
                return {retargeted,hookEntered,errors,instant:turn?.instant===true,active:paginator.pageTurnPreviewActive,
                    index:paginator.displayedIndex,commits:commits.length};
            } finally {
                paginator.removeEventListener('pageturnpreviewload',forward);
                section.load=originalLoad; section.unload=originalUnload;
                URL.revokeObjectURL(url);
            }
        }""")
        self.assertTrue(result['retargeted'], result)
        self.assertTrue(held_requests, 'Expected the forwarded replacement stylesheet to request its resource')
        for route in held_requests:
            route.fulfill(status=200, content_type='text/css', body='body { color: red; }')
        self.assertTrue(result['instant'], 'An old link load cannot authorize painting with its new font sheet pending')
        self.assertFalse(result['active'])
        self.assertEqual((result['index'], result['commits']), (0, 0))
        self.assertTrue(page.evaluate('turn.commit({allowBookEndcap:false})'))
        self.assertEqual(page.evaluate('commits'), [1])

    def test_preview_failure_falls_back_to_normal_navigation(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const errors=[];
            paginator.addEventListener('pageturnerror',e=>errors.push(e.detail.message));
            const fetch=window.fetch;
            window.fetch=() => Promise.reject(new Error('Preview transport failed'));
            let turn;
            try { turn=await paginator.preparePageTurn(1); }
            finally { window.fetch=fetch; }
            const before={index:paginator.displayedIndex,active:paginator.pageTurnPreviewActive,
                sameDocument:paginator.getContents()[0].doc===originalDocument};
            const moved=await turn.commit({allowBookEndcap:false});
            return {before,moved,index:paginator.displayedIndex,errors,commits,
                active:paginator.pageTurnPreviewActive,
                frames:paginatorRoots.get(paginator).querySelectorAll('iframe').length};
        }""")
        self.assertEqual(result['before'], {'index': 0, 'active': False, 'sameDocument': True})
        self.assertTrue(result['moved'])
        self.assertEqual(result['index'], 1)
        self.assertEqual(result['commits'], [1])
        self.assertEqual(result['errors'], ['Preview transport failed'])
        self.assertFalse(result['active'])
        self.assertEqual(result['frames'], 1)

    def test_cancelled_fallback_cannot_turn_later(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            const fetch=window.fetch;
            window.fetch=() => Promise.reject(new Error('Preview transport failed'));
            let turn;
            try { turn=await paginator.preparePageTurn(1); }
            finally { window.fetch=fetch; }
            turn.cancel();
            return {moved:await turn.commit(),index:paginator.displayedIndex,commits,relocations};
        }""")
        self.assertFalse(result['moved'])
        self.assertEqual(result['index'], 0)
        self.assertEqual(result['commits'], [])
        self.assertEqual(result['relocations'], [])

    def test_failed_preview_cannot_acquire_a_newer_gestures_generation(self):
        page = self.open_reader()
        result = page.evaluate("""async () => {
            setEbookViewerPageTurnStyle('slide');
            let replacement;
            paginator.addEventListener('pageturnerror',()=> {
                replacement=paginator.preparePageTurn(-1);
            },{once:true});
            const fetch=window.fetch;
            window.fetch=()=>Promise.reject(new Error('Preview transport failed'));
            let obsolete;
            try { obsolete=await paginator.preparePageTurn(1); }
            finally { window.fetch=fetch; }
            const current=await replacement;
            const result={moved:await obsolete.commit({allowBookEndcap:false}),
                index:paginator.displayedIndex,active:paginator.pageTurnPreviewActive,commits};
            current.cancel();
            return result;
        }""")
        self.assertFalse(result['moved'])
        self.assertEqual(result['index'], 0)
        self.assertTrue(result['active'])
        self.assertEqual(result['commits'], [])

    def test_cleanup_restores_the_sheet_even_when_source_unload_throws(self):
        page = self.open_reader()
        self.prepare(page)
        result = page.evaluate("""() => {
            const errors=[];
            paginator.addEventListener('pageturnerror',e=>errors.push(e.detail.message));
            const section=paginator.sections[1], unload=section.unload;
            section.unload=function() { unload.call(this); throw new Error('Source unload failed'); };
            try { turn.update(.7); turn.cancel(); paginator.cancelPageTurn(); }
            finally { section.unload=unload; }
            const root=paginatorRoots.get(paginator), top=root.querySelector('#top');
            return {errors,active:paginator.pageTurnPreviewActive,
                transform:top.style.transform,visibility:top.style.visibility,
                frames:root.querySelectorAll('iframe').length,index:paginator.displayedIndex};
        }""")
        self.assertEqual(result['errors'], ['Source unload failed'])
        self.assertFalse(result['active'])
        self.assertEqual(result['transform'], '')
        self.assertNotEqual(result['visibility'], 'hidden')
        self.assertEqual(result['frames'], 1)
        self.assertEqual(result['index'], 0)

    def test_terminal_turn_releases_preview_without_moving(self):
        page = self.open_reader()
        page.evaluate('paginator.goTo({index:1,anchor:()=>1})')
        page.evaluate('originalDocument=paginator.getContents()[0].doc; commits=[]; relocations=[];')
        self.prepare(page)
        result = page.evaluate("""async () => ({
            moved:await turn.commit({allowBookEndcap:false}),active:paginator.pageTurnPreviewActive,
            sameDocument:paginator.getContents()[0].doc===originalDocument,commits,relocations
        })""")
        self.assertFalse(result['moved'])
        self.assertFalse(result['active'])
        self.assertTrue(result['sameDocument'])
        self.assertEqual(result['commits'], [])
        self.assertEqual(result['relocations'], [])

    def test_blur_during_commit_does_not_report_no_movement(self):
        page = self.open_reader()
        page.evaluate("""() => {
            setEbookViewerPageTurnStyle('slide');
            const metrics=paginator.pageMetrics.bind(paginator);
            let held=false;
            paginator.pageMetrics=async () => {
                if (paginator.navigationInFlight && !held) {
                    held=true;
                    await new Promise(resolve=>window.releaseCommit=resolve);
                }
                return metrics();
            };
            window.commitResult='pending';
            paginator.next(undefined,{allowBookEndcap:false}).then(result=>window.commitResult=result);
        }""")
        wait_for_reader(page, 'typeof window.releaseCommit === "function"')
        page.evaluate('window.dispatchEvent(new Event("blur"))')
        self.assertEqual(page.evaluate('commitResult'), 'pending')
        page.evaluate('releaseCommit()')
        wait_for_reader(page, 'commitResult !== "pending"')
        self.assertTrue(page.evaluate('commitResult'))
        self.assertEqual(page.evaluate('paginator.displayedIndex'), 1)

    def test_mixed_writing_mode_fallback_releases_its_preview_after_commit(self):
        page = self.open_reader()
        page.evaluate("""async () => {
            const section=paginator.sections[1];
            const src=await section.load();
            const html=await (await fetch(src)).text();
            section.unload();
            const vertical=html.replace('<body ', '<body style="writing-mode:vertical-rl" data-mnb-writing-direction="vertical" ');
            const url=URL.createObjectURL(new Blob([vertical],{type:'text/html'}));
            section.load=async()=>url;
            section.unload=()=>{};
        }""")
        self.prepare(page)
        result = page.evaluate("""async () => ({
            painted:paginator.hasAttribute('data-turn-progress'),
            moved:await turn.commit({allowBookEndcap:false}),
            active:paginator.pageTurnPreviewActive,index:paginator.displayedIndex,
            frames:paginatorRoots.get(paginator).querySelectorAll('iframe').length
        })""")
        self.assertFalse(result['painted'])
        self.assertTrue(result['moved'])
        self.assertFalse(result['active'])
        self.assertEqual(result['index'], 1)
        self.assertEqual(result['frames'], 1)

    def open_long_reader(self, vertical=False):
        page = self.new_reader_page()
        page.add_init_script("""
            window.paginatorRoots = new WeakMap();
            const attach=Element.prototype.attachShadow;
            Element.prototype.attachShadow=function(options) {
                const root=attach.call(this,options);
                if(this.localName==='foliate-paginator') paginatorRoots.set(this,root);
                return root;
            };
        """)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/Tests/Browser/book-endcap.html?long=true&vertical={str(vertical).lower()}')
        page.wait_for_function('window.ready === true')
        return page

    def test_long_horizontal_and_vertical_chapters_advance_one_page(self):
        for vertical in [False, True]:
            with self.subTest(vertical=vertical):
                page = self.open_long_reader(vertical)
                result = page.evaluate("""async () => {
                    const paginator=view.renderer;
                    paginator.setPageTurnStyle('slide');
                    const original=paginator.getContents()[0].doc;
                    const before=await paginator.pageMetrics();
                    const relocated=[];
                    paginator.addEventListener('relocate',e=>relocated.push(e.detail));
                    const turn=await paginator.preparePageTurn(1);
                    if(!turn) throw new Error('Missing within-chapter preview');
                    turn.update(.5);
                    const top=paginatorRoots.get(paginator).querySelector('#top:not(.mnb-slide-sheet)');
                    const matrix=new DOMMatrix(getComputedStyle(top).transform);
                    const midpoint={x:matrix.m41,y:matrix.m42,relocations:relocated.length};
                    const moved=await turn.commit({allowBookEndcap:false});
                    const after=await paginator.pageMetrics();
                    const previewDoc=paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe')?.contentDocument;
                    const nextPreview=await paginator.preparePageTurn(1);
                    const reused=!!previewDoc && paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe')?.contentDocument===previewDoc;
                    nextPreview.cancel();
                    return {before,after,midpoint,moved,reused,sameDocument:paginator.getContents()[0].doc===original,
                        relocations:relocated.length};
                }""")
                self.assertGreater(result['before']['pages'], 3)
                self.assertEqual(result['midpoint']['relocations'], 0)
                self.assertAlmostEqual(abs(result['midpoint']['x']), 195, delta=.1)
                self.assertEqual(result['midpoint']['y'], 0)
                self.assertTrue(result['moved'])
                self.assertTrue(result['sameDocument'])
                self.assertTrue(result['reused'])
                self.assertEqual(result['after']['page'], result['before']['page'] + 1)
                self.assertEqual(result['relocations'], 1)

    def test_uncloneable_paint_uses_one_instant_turn_and_recovers_slide(self):
        for kind in ['canvas', 'adopted', 'video', 'audio', 'iframe', 'object', 'embed']:
            with self.subTest(kind=kind):
                page = self.open_long_reader()
                result = page.evaluate("""async kind => {
                    const paginator=view.renderer;
                    paginator.setPageTurnStyle('slide');
                    const doc=paginator.getContents()[0].doc;
                    const root=paginatorRoots.get(paginator);
                    const before=await paginator.pageMetrics();
                    const events=[];
                    paginator.addEventListener('relocate',event=>events.push(event.detail));
                    // Begin with a reusable preview, then add state which
                    // cannot be copied. Adopted sheets emit no DOM mutation.
                    const initial=await paginator.preparePageTurn(1);
                    const initiallyAnimated=initial?.instant!==true;
                    initial?.cancel();
                    let node;
                    if(kind==='adopted') {
                        const sheet=new doc.defaultView.CSSStyleSheet();
                        sheet.replaceSync('p { background: rgb(91,57,24) !important; }');
                        doc.adoptedStyleSheets=[sheet];
                    } else {
                        node=doc.createElement(kind);
                        Object.assign(node.style,{position:'absolute',top:'0',left:'0',width:'64px',height:'64px'});
                        if(kind==='canvas') {
                            node.width=64;node.height=64;
                            const context=node.getContext('2d');
                            context.fillStyle='red';context.fillRect(0,0,64,64);
                        }
                        doc.body.append(node);
                    }
                    for(let i=0;i<3;i++) await new Promise(requestAnimationFrame);
                    const fallback=await paginator.preparePageTurn(1);
                    const declined=fallback?.instant===true;
                    fallback?.cancel();
                    const unchanged=(await paginator.pageMetrics()).page===before.page && events.length===0;
                    const next=await paginator.preparePageTurn(1);
                    const moved=await next?.commit({allowBookEndcap:false});
                    const after=await paginator.pageMetrics();
                    const turns=events.length;
                    if(kind==='adopted') doc.adoptedStyleSheets=[];
                    else node.remove();
                    for(let i=0;i<3;i++) await new Promise(requestAnimationFrame);
                    const recovered=await paginator.preparePageTurn(1);
                    const animatedAgain=!!recovered && recovered.instant!==true;
                    recovered?.cancel();
                    const frames=root.querySelectorAll('iframe').length;
                    paginator.destroy();
                    return {initiallyAnimated,declined,unchanged,moved,turns,
                        before:before.page,after:after.page,animatedAgain,frames};
                }""", kind)
                self.assertTrue(result['initiallyAnimated'])
                self.assertTrue(result['declined'], result)
                self.assertTrue(result['unchanged'], result)
                self.assertTrue(result['moved'], result)
                self.assertEqual(result['turns'], 1, result)
                self.assertEqual(result['after'], result['before'] + 1)
                self.assertTrue(result['animatedAgain'], result)
                self.assertEqual(result['frames'], 2)

    def test_live_stylesheet_disabled_state_survives_copy_and_cache_reuse(self):
        page = self.open_long_reader()
        result = page.evaluate("""async () => {
            const paginator=view.renderer;
            paginator.setPageTurnStyle('slide');
            const doc=paginator.getContents()[0].doc;
            const style=doc.createElement('style');
            style.textContent='p { background-color: rgb(91, 57, 24) !important; }';
            doc.head.append(style);
            const samples=[];
            // CSSStyleSheet.disabled does not mutate the owning DOM element.
            // Repeated preparation must observe both transitions, including
            // the one made while the prior surface is cached.
            for (const disabled of [true, false, true]) {
                style.sheet.disabled=disabled;
                const live=doc.defaultView.getComputedStyle(doc.querySelector('p')).backgroundColor;
                const turn=await paginator.preparePageTurn(1);
                const preview=paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe')?.contentDocument;
                const painted=preview?.defaultView.getComputedStyle(preview.querySelector('p')).backgroundColor;
                samples.push({disabled,live,painted,instant:turn?.instant===true});
                turn?.cancel();
            }
            paginator.destroy();
            return samples;
        }""")
        self.assertEqual([sample['live'] for sample in result], ['rgba(0, 0, 0, 0)', 'rgb(91, 57, 24)', 'rgba(0, 0, 0, 0)'])
        for sample in result:
            self.assertFalse(sample['instant'])
            self.assertEqual(sample['painted'], sample['live'], sample)

    def test_live_stylesheet_media_cssom_survives_copy_and_cache_reuse(self):
        for inline in [True, False]:
            with self.subTest(inline=inline):
                page = self.open_long_reader()
                page.route('**/slide-media/paint.css', lambda route: route.fulfill(
                    status=200, content_type='text/css',
                    body='p { background-color: rgb(91, 57, 24) !important; }'))
                result = page.evaluate("""async inline => {
                    const paginator=view.renderer;
                    paginator.setPageTurnStyle('slide');
                    const doc=paginator.getContents()[0].doc;
                    const node=doc.createElement(inline?'style':'link');
                    node.media='all';
                    if (inline) {
                        node.textContent='p { background-color: rgb(91, 57, 24) !important; }';
                        doc.head.append(node);
                    } else {
                        node.rel='stylesheet'; node.href=location.origin+'/slide-media/paint.css';
                        await new Promise((resolve,reject)=>{
                            node.onload=resolve; node.onerror=reject; doc.head.append(node);
                        });
                    }
                    const sample=doc=>doc.defaultView.getComputedStyle(doc.querySelector('p')).backgroundColor;
                    const samples=[];
                    for (const media of ['not all','all','not all','all']) {
                        // MediaList changes do not mutate the owning node or
                        // notify the preview's DOM mutation observer.
                        node.sheet.media.mediaText=media;
                        const live=sample(doc);
                        const turn=await paginator.preparePageTurn(1);
                        const preview=paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe')?.contentDocument;
                        samples.push({media,attribute:node.getAttribute('media'),live,
                            painted:preview?sample(preview):null,instant:turn?.instant===true});
                        turn?.cancel();
                    }
                    paginator.destroy();
                    return samples;
                }""", inline)
                self.assertEqual([sample['live'] for sample in result],
                                 ['rgba(0, 0, 0, 0)', 'rgb(91, 57, 24)'] * 2)
                for sample in result:
                    self.assertEqual(sample['attribute'], 'all')
                    self.assertFalse(sample['instant'])
                    self.assertEqual(sample['painted'], sample['live'], sample)

    def test_live_inline_cssom_edits_survive_copy_and_cache_reuse(self):
        page = self.open_long_reader()
        result = page.evaluate("""async () => {
            const paginator=view.renderer;
            paginator.setPageTurnStyle('slide');
            const doc=paginator.getContents()[0].doc;
            const style=doc.createElement('style');
            style.textContent='p { background-color: transparent !important; }';
            doc.head.append(style);
            const samples=[];
            for (const color of ['rgb(91, 57, 24)', 'rgb(57, 91, 24)', null]) {
                if (style.sheet.cssRules.length) style.sheet.deleteRule(0);
                if (color !== null) style.sheet.insertRule('p { background-color: '+color+' !important; }');
                const live=doc.defaultView.getComputedStyle(doc.querySelector('p')).backgroundColor;
                const turn=await paginator.preparePageTurn(1);
                const preview=paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe')?.contentDocument;
                const painted=preview?.defaultView.getComputedStyle(preview.querySelector('p')).backgroundColor;
                samples.push({live,painted,instant:turn?.instant===true});
                turn?.cancel();
            }
            paginator.destroy();
            return samples;
        }""")
        self.assertEqual([sample['live'] for sample in result], ['rgb(91, 57, 24)', 'rgb(57, 91, 24)', 'rgba(0, 0, 0, 0)'])
        for sample in result:
            self.assertFalse(sample['instant'])
            self.assertEqual(sample['painted'], sample['live'], sample)

    def test_live_linked_cssom_edits_preserve_resource_base_and_cache_state(self):
        page = self.open_long_reader()
        page.route('**/slide-css/styles.css', lambda route: route.fulfill(
            status=200, content_type='text/css', body='p { --linked-sheet-ready: yes; }'))
        page.route('**/slide-css/paper.svg', lambda route: route.fulfill(
            status=200, content_type='image/svg+xml',
            body='<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'))
        result = page.evaluate("""async () => {
            const paginator=view.renderer;
            paginator.setPageTurnStyle('slide');
            const doc=paginator.getContents()[0].doc;
            const link=doc.createElement('link');
            link.rel='stylesheet'; link.href=location.origin+'/slide-css/styles.css';
            await new Promise((resolve,reject)=>{
                link.onload=resolve; link.onerror=reject; doc.head.append(link);
            });
            const sample=doc=>{
                const style=doc.defaultView.getComputedStyle(doc.querySelector('p'));
                return {color:style.color,background:style.backgroundImage};
            };
            const samples=[];
            for (const color of ['rgb(91, 57, 24)', 'rgb(57, 91, 24)', null]) {
                if (link.sheet.cssRules.length>1) link.sheet.deleteRule(1);
                if (color!==null) link.sheet.insertRule('p {color:'+color+' !important;'
                    +'background-image:url("./paper.svg") !important;}',1);
                const live=sample(doc);
                const turn=await paginator.preparePageTurn(1);
                const preview=paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe')?.contentDocument;
                samples.push({live,painted:preview?sample(preview):null,instant:turn?.instant===true});
                turn?.cancel();
            }
            paginator.destroy();
            return samples;
        }""")
        self.assertEqual(result[0]['live']['color'], 'rgb(91, 57, 24)')
        self.assertEqual(result[1]['live']['color'], 'rgb(57, 91, 24)')
        self.assertTrue(result[0]['live']['background'].endswith('/slide-css/paper.svg")'))
        self.assertEqual(result[2]['live']['background'], 'none')
        for sample in result:
            self.assertFalse(sample['instant'])
            self.assertEqual(sample['painted'], sample['live'], sample)

    def test_live_linked_cssom_import_is_ready_before_preview_paint_hooks(self):
        page = self.open_long_reader()
        page.route('**/slide-import/styles.css', lambda route: route.fulfill(
            status=200, content_type='text/css', body='p { --linked-sheet-ready: yes; }'))
        requests = []
        held_requests = []
        released = False
        preparing_preview = False

        def serve_import(route):
            requests.append(route.request.url)
            if not preparing_preview or released:
                route.fulfill(status=200, content_type='text/css',
                              body=':root { --linked-import-ready: yes; }')
            else:
                held_requests.append(route)

        page.route('**/slide-import/imported.css', serve_import)
        page.evaluate("""async () => {
            const paginator=view.renderer;
            const doc=paginator.getContents()[0].doc;
            const link=doc.createElement('link');
            link.rel='stylesheet'; link.href=location.origin+'/slide-import/styles.css';
            await new Promise((resolve,reject)=>{
                link.onload=resolve; link.onerror=reject; doc.head.append(link);
            });
            window.linkedImportSource=doc;
            window.linkedImportSourceLink=link;
            window.importPaint=null;
            paginator.addEventListener('pageturnpreviewload',({detail:{doc}})=>{
                importPaint=doc.defaultView.getComputedStyle(doc.documentElement).getPropertyValue('--linked-import-ready').trim();
            });
        }""")
        wait_for_reader(page, 'linkedImportSource.defaultView.getComputedStyle(linkedImportSource.querySelector("p")).getPropertyValue("--linked-sheet-ready").trim()==="yes"', timeout=5000)
        page.evaluate('linkedImportSourceLink.sheet.insertRule(\'@import "./imported.css";\',0)')
        wait_for_reader(page, 'linkedImportSourceLink.sheet.cssRules[0].styleSheet?.cssRules.length > 0', timeout=5000)
        page.evaluate('view.renderer.setPageTurnStyle("slide")')
        preparing_preview = True
        with page.expect_request(lambda request: request.url.endswith('/slide-import/imported.css')):
            page.evaluate('window.linkedImportPreparation=view.renderer.preparePageTurn(1); void 0')
        before = page.evaluate('importPaint')
        released = True
        for route in held_requests:
            route.fulfill(status=200, content_type='text/css',
                          body=':root { --linked-import-ready: yes; }')
        result = page.evaluate("""async () => {
            const turn=await linkedImportPreparation;
            const result={paint:importPaint,instant:turn?.instant===true};
            turn?.cancel(); view.renderer.destroy();
            return result;
        }""")
        self.assertGreaterEqual(len(requests), 2)
        self.assertTrue(held_requests)
        self.assertIsNone(before, 'Restored CSSOM imports must settle before paint hooks run')
        self.assertEqual(result, {'paint': 'yes', 'instant': False})

    def test_nested_import_cssom_edits_preserve_live_paint_and_cache_state(self):
        for inline in [False, True]:
            with self.subTest(inline=inline):
                page = self.open_long_reader()
                for path, css in [
                    ('root.css', '@import "./middle/middle.css";'),
                    ('middle/middle.css', '@import "./leaf/paint.css";'),
                    ('middle/leaf/paint.css', 'p { background-color: rgb(10, 20, 30); '
                     'background-image: url("./paper.svg") !important; }'),
                ]:
                    page.route('**/nested-swipe/' + path, lambda route, *, css=css: route.fulfill(
                        status=200, content_type='text/css', body=css))
                page.route('**/nested-swipe/middle/leaf/paper.svg', lambda route: route.fulfill(
                    status=200, content_type='image/svg+xml',
                    body='<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'))
                page.evaluate("""async inline => {
                    const doc=view.renderer.getContents()[0].doc;
                    const node=doc.createElement(inline?'style':'link');
                    const url=location.origin+'/nested-swipe/root.css';
                    if(inline) node.textContent='@import url("'+url+'");';
                    else { node.rel='stylesheet'; node.href=url; }
                    doc.head.append(node);
                    window.importSource=doc;
                    window.importRoot=node;
                }""", inline)
                wait_for_reader(page, 'importSource.defaultView.getComputedStyle(importSource.querySelector("p")).backgroundColor==="rgb(10, 20, 30)"')
                result = page.evaluate("""async () => {
                    const paginator=view.renderer;
                    paginator.setPageTurnStyle('slide');
                    const sample=doc=>{
                        const style=doc.defaultView.getComputedStyle(doc.querySelector('p'));
                        return {color:style.backgroundColor,image:style.backgroundImage};
                    };
                    let leaf=importRoot.sheet;
                    while(leaf.cssRules[0].type===CSSRule.IMPORT_RULE) leaf=leaf.cssRules[0].styleSheet;
                    const results=[];
                    for(const color of ['rgb(91, 57, 24)','rgb(57, 91, 24)','rgb(10, 20, 30)']) {
                        // The root @import text and all DOM nodes stay unchanged.
                        leaf.cssRules[0].style.setProperty('background-color',color,'important');
                        const live=sample(importSource);
                        const turn=await paginator.preparePageTurn(1);
                        const preview=paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet iframe')?.contentDocument;
                        results.push({expected:color,live,painted:preview?sample(preview):null,instant:turn?.instant===true});
                        turn?.cancel();
                    }
                    paginator.destroy();
                    return results;
                }""")
                for sample in result:
                    self.assertEqual(sample['live']['color'], sample['expected'])
                    self.assertTrue(sample['live']['image'].endswith('/nested-swipe/middle/leaf/paper.svg")'))
                    self.assertFalse(sample['instant'])
                    self.assertEqual(sample['painted'], sample['live'], sample)

    def test_preview_cancellation_releases_work_without_another_animation_frame(self):
        for stage in ['copy', 'stylesheet']:
            with self.subTest(stage=stage):
                page = self.new_reader_page()
                page.route('**/cancel-preview.html', lambda route: route.fulfill(
                    status=200, content_type='text/html', body='<!doctype html><html><body></body></html>'))
                held_requests = []
                page.route('**/cancel-preview.css', lambda route: held_requests.append(route))
                page.goto(f'http://127.0.0.1:{self.server.server_port}/cancel-preview.html')
                page.evaluate("""async stage => {
                    const {preparePageTurnPreviewDocument}=await import('/load/viewer-assets/foliate-js/page-turn-preview.js');
                    const frame=document.createElement('iframe');
                    frame.sandbox='allow-same-origin'; document.body.append(frame);
                    const source=new DOMParser().parseFromString('<!doctype html><html><head>'
                        +(stage==='stylesheet'?'<link rel="stylesheet" href="/cancel-preview.css">':'')
                        +'</head><body>Preview cancellation</body></html>','text/html');
                    const raf=window.requestAnimationFrame,cancel=window.cancelAnimationFrame;
                    const frames=new Map(); let sequence=0;
                    window.requestAnimationFrame=callback=>{frames.set(++sequence,callback);return sequence;};
                    window.cancelAnimationFrame=id=>frames.delete(id);
                    const abort=new AbortController();
                    window.pausedPreview={frames,abort,frame,hooks:0};
                    window.restorePausedPreview=()=>{
                        abort.abort(); frames.clear();
                        window.requestAnimationFrame=raf; window.cancelAnimationFrame=cancel;
                        frame.remove();
                    };
                    pausedPreview.preparation=preparePageTurnPreviewDocument(frame.contentDocument,source,
                        location.origin+'/',()=>!abort.signal.aborted,()=>pausedPreview.hooks++,abort.signal);
                    if(stage==='stylesheet') {
                        // Let the copy frame run, then pause stylesheet polling.
                        const [id,callback]=frames.entries().next().value;
                        frames.delete(id); callback(performance.now());
                    }
                }""", stage)
                try:
                    if stage == 'stylesheet':
                        wait_for_reader(page, 'pausedPreview.frames.size===1 && pausedPreview.frame.contentDocument.querySelector("link")')
                    result = page.evaluate("""async () => {
                        const before=pausedPreview.frames.size;
                        pausedPreview.abort.abort();
                        const settled=await Promise.race([
                            pausedPreview.preparation.then(value=>({done:true,value})),
                            new Promise(resolve=>setTimeout(()=>resolve({done:false}),100)),
                        ]);
                        return {before,remaining:pausedPreview.frames.size,hooks:pausedPreview.hooks,...settled};
                    }""")
                    self.assertEqual(result, {'before': 1, 'remaining': 0, 'hooks': 0, 'done': True, 'value': False})
                finally:
                    for route in held_requests:
                        route.fulfill(status=200, content_type='text/css', body='body { color: blue; }')
                    page.evaluate('restorePausedPreview()')


if __name__ == '__main__':
    unittest.main()
