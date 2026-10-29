"""Run the actual viewer using the assets selected for every non-Debug app."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import uuid

import test_layered_page_turn as slide
from browser_wait import wait_for_reader


class PackagedReaderResourceTests(unittest.TestCase):
    debug = False

    @classmethod
    def setUpClass(cls):
        source = slide.shell.ASSETS
        # Repository-owned packaging tool, also invoked by Tuist before signing.
        script = Path(__file__).resolve().parents[4] / "scripts/package_reader_resources.py"
        spec = importlib.util.spec_from_file_location("reader_packaging", script)
        packaging = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packaging)
        cls.temporary = Path(tempfile.mkdtemp(prefix="reader-distribution-test-")).resolve(strict=True)
        cls.addClassCleanup(lambda: shutil.move(str(cls.temporary), str(
            (Path.home() / ".Trash").resolve(strict=True) / (cls.temporary.name + "-" + uuid.uuid4().hex))))
        product = cls.temporary / "foliate-js"
        product.mkdir()
        packaging.package_foliate(source, product, cls.debug, cls.temporary / "trash")
        cls.addClassCleanup(setattr, slide.shell, "ASSETS", source)
        slide.shell.ASSETS = product
        cls.addClassCleanup(slide.LayeredPageTurnTests.doClassCleanups)
        slide.LayeredPageTurnTests.setUpClass()

    def open_reader(self, saved_style=None):
        fixture = slide.LayeredPageTurnTests()
        self.addCleanup(fixture.doCleanups)
        return fixture.open_reader(page_turn=saved_style)


class DistributedReaderResourcesTests(PackagedReaderResourceTests):
    def test_distributed_viewer_cannot_enable_development_slide(self):
        for saved_style in [None, "slide"]:
            with self.subTest(saved_style=saved_style):
                page = self.open_reader(saved_style)
                result = page.evaluate("""() => ({
                    setter:typeof window.setEbookViewerPageTurnStyle,
                    rendererSetter:typeof paginator.setPageTurnStyle,
                    prepare:typeof paginator.preparePageTurn,
                    corners:getComputedStyle(paginator).borderTopLeftRadius,
                    expanded:reader.view.hasAttribute('data-slide-pages'),
                    frames:paginatorRoots.get(paginator).querySelectorAll('iframe').length
                })""")
                self.assertEqual(result, {"setter": "undefined", "rendererSetter": "undefined",
                    "prepare": "undefined", "corners": "0px", "expanded": False, "frames": 1})

    def test_distributed_viewer_retains_normal_page_navigation(self):
        page = self.open_reader()
        self.assertTrue(page.evaluate("paginator.next(undefined,{allowBookEndcap:false})"))
        wait_for_reader(page, "paginator.displayedIndex === 1")
        self.assertEqual(page.evaluate("commits"), [1])
        self.assertTrue(page.evaluate("paginator.prev(undefined,{allowBookEndcap:false})"))
        wait_for_reader(page, "paginator.displayedIndex === 0")
        self.assertEqual(page.evaluate("commits"), [1, 0])


class DebugReaderResourcesTests(PackagedReaderResourceTests):
    debug = True

    def test_debug_packaged_slide_prepares_and_commits(self):
        page = self.open_reader("slide")
        result = page.evaluate("""async () => {
            const turn=await paginator.preparePageTurn(1);
            const animated=!!turn && turn.instant!==true;
            turn?.update(.4);
            const preview=paginatorRoots.get(paginator).querySelector('.mnb-slide-sheet');
            const visible=!!preview && getComputedStyle(preview).visibility==='visible';
            const moved=await turn?.commit({allowBookEndcap:false});
            return {animated,visible,moved,index:paginator.displayedIndex,commits};
        }""")
        self.assertEqual(result, {"animated": True, "visible": True, "moved": True, "index": 1, "commits": [1]})
