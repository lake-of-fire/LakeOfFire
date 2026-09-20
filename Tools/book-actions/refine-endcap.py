#!/usr/bin/env python3
from pathlib import Path

root = Path('Sources/LakeOfFireReader/Resources/Resources/foliate-js')
def replace(name, old, new):
    path = root / name
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError(f'{name}: expected one exact reviewed anchor: {old[:100]}')
    path.write_text(source.replace(old, new))

replace('paginator.js',
    'if (!this.#destroyed && !this.navigationInFlight && this.bookEndcap?.visible) {\n            if (dir < 0)',
    'if (!this.#destroyed && !this.navigationInFlight && this.bookEndcap?.visible) {\n            if (options.allowBookEndcap === false) return { authoritativeNoMove: true }\n            if (dir < 0)')
replace('paginator.js',
    'if (dir > 0 && beforeAdjacentIndex == null && !this.#isCacheWarmer\n                    && this.bookEndcap?.enter())',
    'if (dir > 0 && beforeAdjacentIndex == null && !this.#isCacheWarmer\n                    && options.allowBookEndcap !== false && this.bookEndcap?.enter())')
replace('paginator.js',
    '    async nextSection() {\n        if (this.#adjacentIndex(1) == null && this.bookEndcap) return await this.next()',
    '''    async nextSection(options = {}) {
        if (this.#adjacentIndex(1) == null && this.bookEndcap) {
            return options.allowBookEndcap === false ? false : await this.next(undefined, options)
        }''')
replace('fixed-layout.js',
    '                return this.bookEndcap?.enter()\n                    ? { authoritativeNoMove: true, endcapNavigation: true } : false',
    '                return options.allowBookEndcap !== false && this.bookEndcap?.enter()\n                    ? { authoritativeNoMove: true, endcapNavigation: true } : false')
replace('fixed-layout.js',
    '            if (this.bookEndcap?.visible) {\n                this.bookEndcap.leave()',
    '            if (this.bookEndcap?.visible) {\n                if (options.allowBookEndcap === false) return { authoritativeNoMove: true }\n                this.bookEndcap.leave()')
replace('renderer-navigation.js',
    'operation: () => renderer.nextSection(),',
    'operation: () => renderer.nextSection({ allowBookEndcap: false }),')
replace('ebook-viewer.js',
    '''                const turnOptions = {
                    ignoreIfPageTurnInFlight,
                    ignoreIfNavigationInFlight: true,
                };''',
    '''                const turnOptions = {
                    ignoreIfPageTurnInFlight,
                    ignoreIfNavigationInFlight: true,
                    allowBookEndcap: navigationDetails.allowBookEndcap !== false,
                };''')
replace('ebook-viewer.js',
    '''                deferVisiblePageResetUntilMovement: true,
                ignoreIfPageTurnInFlight: true,''',
    '''                deferVisiblePageResetUntilMovement: true,
                ignoreIfPageTurnInFlight: true,
                allowBookEndcap: false,''')
replace('ebook-viewer.js',
    "        const isExcludedTouchTarget = target.closest?.('#reader-stage, #side-bar, #page-tracking-container, #nav-hidden-overlay, .side-nav, input, textarea, select, button, a, [role=\"button\"], [contenteditable=\"true\"]');",
    '''        const isEndcapBackground = this.bookEndcap?.visible === true
            && target.closest?.('.manabi-book-endcap')
            && !target.closest?.('input, textarea, select, button, a, [role="button"], [contenteditable="true"]');
        const isExcludedTouchTarget = !isEndcapBackground && target.closest?.('#reader-stage, #side-bar, #page-tracking-container, #nav-hidden-overlay, .side-nav, input, textarea, select, button, a, [role="button"], [contenteditable="true"]');''')

path = Path('Tests/JavaScript/fixed-layout.test.mjs')
source = path.read_text()
source += '''

test('terminal endcap preserves spine identity and rejects lookup-owned navigation', async () => {
    const sections = [{linear:'yes',load:async()=>'page-0'},{linear:'no',load:async()=>'supplement'}]
    const layout = new FixedLayout()
    let entered=0, left=0, relocations=0
    layout.open({dir:'ltr',rendition:{viewport:{width:1000,height:1000}},sections})
    await layout.goTo({index:0})
    layout.addEventListener('relocate',()=>relocations++)
    layout.bookEndcap={visible:false,enter(){if(this.visible)return false;entered++;this.visible=true;return true},leave(){left++;this.visible=false}}
    assert.equal(await layout.next(undefined,{allowBookEndcap:false}),false)
    assert.equal(entered,0)
    const result=await layout.next()
    assert.equal(result.endcapNavigation,true)
    assert.equal(result.authoritativeNoMove,true)
    assert.equal(layout.currentIndex,0)
    assert.equal(entered,1)
    assert.equal(await layout.next(),false)
    assert.equal((await layout.prev(undefined,{allowBookEndcap:false})).authoritativeNoMove,true)
    assert.equal(left,0)
    assert.equal((await layout.prev()).endcapNavigation,true)
    assert.equal(left,1)
    assert.equal(layout.currentIndex,0)
    assert.equal(sections.length,2)
    assert.equal(relocations,0)
    layout.destroy()
})
'''
path.write_text(source)
