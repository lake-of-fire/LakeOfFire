"""Temporary exact-input viewer surgery; removed after immutable blob publication."""
from pathlib import Path
import hashlib

path = Path('Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js')

def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()

assert blob(path.read_bytes()) == '89b52d3a470fab257950b581497fa4c5606155f6'
source = path.read_text()

def replace_once(old, new):
    global source
    assert source.count(old) == 1
    source = source.replace(old, new)

def replace_region(start, end, replacement):
    global source
    assert source.count(start) == source.count(end) == 1
    first = source.index(start)
    last = source.index(end, first)
    source = source[:first] + replacement + source[last:]

replace_once("""import {
    makeInitialRestoreTerminalResult,
    makeSyntheticRestoreLocator,
    normalizeInitialRestoreRequest,
    parseSyntheticRestoreLocator,
    restoreLocatorKind as classifyRestoreLocator,
    runRequiredRestoreNavigation,
    shouldSkipScheduledReaderFractionGoTo,
} from './ebook-restore-coordination.js'
import { CacheWarmerOpenIntent } from './cache-warmer-open-intent.js'
import { CacheWarmerPrecedingSections } from './cache-warmer-preceding-sections.js'
import { DeferredOpenWorkCoordinator } from './deferred-open-work.js'
import { EbookLoadResources } from './ebook-load-resources.js'
""", """import {
    makeSyntheticRestoreLocator,
    shouldSkipScheduledReaderFractionGoTo,
} from './ebook-restore-coordination.js'
import { CacheWarmerOpenIntent } from './cache-warmer-open-intent.js'
import { CacheWarmerPrecedingSections } from './cache-warmer-preceding-sections.js'
import { DeferredOpenWorkCoordinator } from './deferred-open-work.js'
""")
replace_region('const runWithNavigationIntent = async ', '\nconst shouldSkipScheduledReaderFractionGoToForRestoreSettling', """import { createEbookLoadHandlers, createNavigationIntentRunner } from './ebook-load-coordinator.js'

const runWithNavigationIntent = createNavigationIntentRunner();
""")
replace_once("""        this.#closed = true
        this.nativeMarkReadRequestCoordinator?.cancelAll?.(`readerClosed:${_reason}`)""", """        this.#closed = true
        this.onLoadClosed?.()
        this.nativeMarkReadRequestCoordinator?.cancelAll?.(`readerClosed:${_reason}`)""")
replace_region('window.loadEBook = ({', '\nconst markRestorePositionSaveUserInput', """const ebookLoadHandlers = createEbookLoadHandlers({
    Reader,
    CacheWarmer,
    makeNativeSource,
    makeFileSource,
    installReaderPresentationState,
    beginReplaceTextCacheGeneration,
    beginForegroundCriticalSection,
    finishForegroundCriticalSection,
    ensureRestorePositionSaveUserInputTracking: () => ensureRestorePositionSaveUserInputTracking(),
    runWithNavigationIntent,
    markReaderRenderReady,
    postLandscapeInsetRestoreProbe,
    scheduleDeferredCacheWarmerOpen,
});
window.loadEBook = ebookLoadHandlers.loadEBook;
""")
replace_region('window.loadLastPosition = async ({', '\nwindow.refreshBookReadingProgress',
               'window.loadLastPosition = ebookLoadHandlers.loadLastPosition;\n')
assert blob(source.encode()) == 'cf8c66e1f65aa48bdab0cf741bec5a14b530fc76'
path.write_text(source)
for name, expected in [
    ('Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js', '3e4b2b935ee3c26a4673d8f89b1356fd5043e59e'),
    ('Tests/JavaScript/ebook-load-coordinator.test.mjs', 'c497cf4831b19357f7e386f1e3adb53d39080a3d'),
]:
    assert blob(Path(name).read_bytes()) == expected, name
print('EXACT_LOADER_SOURCE_VERIFIED')
