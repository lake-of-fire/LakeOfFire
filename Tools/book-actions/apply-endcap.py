#!/usr/bin/env python3
"""Apply the reviewed endcap changes to this isolated feature branch.

This source transform fails on missing/ambiguous anchors rather than guessing.
New modules and behavioral tests live beside the existing production sources.
"""
from pathlib import Path

P = Path('Sources/LakeOfFireReader/Resources/Resources/foliate-js')

def replace(file, old, new, expected=1):
    path = P / file
    source = path.read_text()
    count = source.count(old)
    if count != expected:
        raise RuntimeError(f'{file}: expected {expected} matching anchors, got {count}: {old[:90]}')
    path.write_text(source.replace(old, new))

replace('paginator.js', '    async #turnPage(dir, distance, options = {}) {', '''    async #turnPage(dir, distance, options = {}) {
        // An endcap is a shell location. Back returns to the same last page;
        // forward on it is inert. Neither is evidence of physical movement.
        if (!this.#destroyed && !this.navigationInFlight && this.bookEndcap?.visible) {
            if (dir < 0) this.bookEndcap.leave()
            return { authoritativeNoMove: true, endcapNavigation: true }
        }''')
replace('paginator.js', '            if (scrollDecision?.authoritativeNoMove === true) return false', '''            if (scrollDecision?.authoritativeNoMove === true) {
                if (dir > 0 && beforeAdjacentIndex == null && !this.#isCacheWarmer
                    && this.bookEndcap?.enter()) {
                    return { authoritativeNoMove: true, endcapNavigation: true }
                }
                return false
            }''')
replace('paginator.js', '            return await this.#goTo(resolved, owner)', '''            this.bookEndcap?.leave({ restoreFocus: false })
            return await this.#goTo(resolved, owner)''')
replace('paginator.js', '''    async nextSection() {
        return await this.goTo({''', '''    async nextSection() {
        if (this.#adjacentIndex(1) == null && this.bookEndcap) return await this.next()
        return await this.goTo({''')
replace('paginator.js', '''    async canTurnNext() {
        if (!this.#view) return false;''', '''    async canTurnNext() {
        if (!this.#view) return false;
        if (this.bookEndcap) return !this.bookEndcap.visible;''')
replace('paginator.js', '''    async canTurnPrev() {
        if (!this.#view) return false;''', '''    async canTurnPrev() {
        if (!this.#view) return false;
        if (this.bookEndcap?.visible) return true;''')
replace('fixed-layout.js', '''            if (!spreadTarget) return false
            return await this.#goToSpread(''', '''            if (!spreadTarget) return false
            this.bookEndcap?.leave({ restoreFocus: false })
            return await this.#goToSpread(''')
replace('fixed-layout.js', '            const s = this.rtl ? this.#goLeft() : this.#goRight()', '''            if (this.bookEndcap?.visible) return false
            const s = this.rtl ? this.#goLeft() : this.#goRight()''')
replace('fixed-layout.js', '            const s = this.rtl ? this.#goRight() : this.#goLeft()', '''            if (this.bookEndcap?.visible) {
                this.bookEndcap.leave()
                return { authoritativeNoMove: true, endcapNavigation: true }
            }
            const s = this.rtl ? this.#goRight() : this.#goLeft()''')
source = (P / 'fixed-layout.js').read_text()
start = source.index('    async next(')
end = source.index('    async prev(', start)
part = source[start:end]
assert part.count('            if (!targetSide) return false') == 1
part = part.replace('            if (!targetSide) return false', '''            if (!targetSide) {
                return this.bookEndcap?.enter()
                    ? { authoritativeNoMove: true, endcapNavigation: true } : false
            }''')
(P / 'fixed-layout.js').write_text(source[:start] + part + source[end:])
replace('ebook-viewer.js', 'import { NavigationHUD }', "import { BookEndcap, createBookActionBridge } from './book-endcap.js'\nimport { NavigationHUD }")
replace('ebook-viewer.js', '    #completionActionSequence = 0;', '    #completionActionSequence = 0;\n    bookEndcap = null;\n    bookActionBridge = null;')
replace('ebook-viewer.js', '''        const view = this.view;
        this.view = null;''', '''        this.bookEndcap?.destroy();
        this.bookActionBridge?.close();
        this.bookEndcap = null;
        this.bookActionBridge = null;
        const view = this.view;
        this.view = null;''')
source = (P / 'ebook-viewer.js').read_text()
start = source.index('    async #handleCompletionAction(actionType) {')
end = source.index('    #currentSectionReadState()', start)
source = source[:start] + source[end:]
start = source.index('        const completionAction = this.completionAction;', source.index('    async markVisiblePageAsRead('))
end = source.index("        const stateID = 'visible-screen';", start)
source = source[:start] + '        if (this.bookEndcap?.visible) return false;\n' + source[end:]
source = source.replace('                this.#handleCompletionAction(completionAction).catch((error) => console.error(error));', '                return; // Completion is only available on the endcap.')
start = source.index('        const isSinglePageMetadataSection =', source.index('    async updateNavButtons('))
end = source.index('        this.#show(this.buttons.prev', start)
source = source[:start] + '''        this.completionAction = null;
        this.#invalidateCompletionAction();
        const endcapVisible = this.bookEndcap?.visible === true;
        const forwardIsDisabled = this.bookEndcap
            ? endcapVisible : (atSectionEnd && !hasNextSection);
        const backwardIsDisabled = !endcapVisible && atSectionStart && !hasPrevSection;

''' + source[end:]
source = source.replace('compactSheetSidePaginationDisabled || (atSectionEnd && !hasNextSection)', 'compactSheetSidePaginationDisabled || forwardIsDisabled')
source = source.replace('compactSheetSidePaginationDisabled || (atSectionStart && !hasPrevSection)', 'compactSheetSidePaginationDisabled || backwardIsDisabled')
source = source.replace("const markReadButtonsVisible = document.body?.dataset?.mnbMarkReadButtonsVisible !== 'false';", "const markReadButtonsVisible = !this.bookEndcap?.visible && document.body?.dataset?.mnbMarkReadButtonsVisible !== 'false';")
needle = '        const initialRestore = options?.initialRestore ?? null;'
assert source.count(needle) == 1
source = source.replace(needle, '''        const bookActionHandler = window.webkit?.messageHandlers?.ebookBookAction;
        if (bookActionHandler) {
            this.bookActionBridge = createBookActionBridge({
                postMessage: payload => bookActionHandler.postMessage(payload),
                documentStartedAtMs: readerDocumentStartedAtMs(),
                topWindowURL: window.top.location.href,
            });
            this.bookEndcap = new BookEndcap({
                document,
                host: document.getElementById('reader-stage'),
                publication: view,
                performAction: action => this.bookActionBridge.perform(action),
                onChange: visible => {
                    this.#clearOptimisticMarkReadState('book-endcap');
                    this.#renderPageTrackingButtons('book-endcap');
                    void this.updateNavButtons();
                },
            });
            view.renderer.bookEndcap = this.bookEndcap;
            this.bookEndcap.setFinished(this.markedAsFinished);
        }
        const initialRestore = options?.initialRestore ?? null;''')
source = source.replace('        this.markedAsFinished = !!this.articleReadingProgress.articleMarkedAsFinished;', '''        this.markedAsFinished = !!this.articleReadingProgress.articleMarkedAsFinished;
        this.bookEndcap?.setFinished(this.markedAsFinished);''')
source += '''\n// The host replies to this reader's request ID; another reader cannot consume it.
window.manabi_bookActionDidComplete = (requestID, result) =>
    globalThis.reader?.bookActionBridge?.acknowledge(requestID, result) ?? false;
'''
(P / 'ebook-viewer.js').write_text(source)
replace('ebook-viewer.html', '    </head>', '        <link rel="stylesheet" href="./book-endcap.css">\n    </head>')
