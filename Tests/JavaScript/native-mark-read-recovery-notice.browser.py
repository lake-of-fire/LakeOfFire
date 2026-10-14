"""Check native reading-outcome notices in real Chromium DOM.

Loads the complete production modules offline, rewriting only import URLs to
Blob URLs. Native replies, query completion and timers are controlled; this is
not WKWebView, native-writer or complete Reader qualification.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "Sources/LakeOfFireReader/Resources/Resources/foliate-js"
MODULES = ("native-mark-read-request.js", "reader-producer-evidence.js",
           "book-reading-state.js", "cryptographic-uuid.js")

CASE = r"""async ({kind, desired, sources}) => {
    const urls = new Map();
    const moduleURL = name => {
        if (urls.has(name)) return urls.get(name);
        const text = sources[name].replace(/from '\.\/([^']+)'/g,
            (_, dependency) => `from '${moduleURL(dependency)}'`);
        const url = URL.createObjectURL(new Blob([text], {type: 'text/javascript'}));
        urls.set(name, url);
        return url;
    };
    const module = await import(moduleURL('native-mark-read-request.js'));
    const commands = [], controls = [], timers = new Map();
    let next = 0, completeQuery;
    const query = new Promise(resolve => { completeQuery = resolve; });
    const coordinator = module.createNativeMarkReadRequestCoordinator({
        postMessage: message => commands.push(message),
        postControlMessage: message => controls.push(message),
        onPending: module.presentNativeMarkReadPending,
        onRecovery: () => true, onRecoveryQuery: () => query,
        scheduleTimeout: callback => { const id = ++next; timers.set(id, callback); return id; },
        cancelTimeout: id => timers.delete(id), lifecycleTarget: window,
    });
    const check = (condition, reason) => { if (!condition) throw new Error(reason); };
    try {
        const command = coordinator.request({sectionID: 'page', message: {desiredState: desired}});
        coordinator.pause(); coordinator.resume();
        const original = document.querySelector('.mnb-native-mark-pending');
        const message = commands[0];
        check(coordinator.settle({requestID: message.requestID, manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: message.manualReadPendingObservationToken,
            manualReadPendingHistoryRecovery: true, manualReadPendingOutcomeOnly: true,
            manualReadPendingPresentationAllowed: false,
            ...(kind === 'unavailable'
                ? {manualReadPendingState: 'unavailable', errorCode: 'outcomeUnavailable'}
                : {manualReadPendingState: 'finished', success: kind === 'success'})}),
            'Native terminal was not accepted');
        const result = await command;
        const notice = document.querySelector('.mnb-native-mark-pending');
        const label = notice.firstElementChild.textContent;
        const expected = kind === 'success' ? 'The reading change was saved.'
            : kind === 'failure' ? 'The reading change wasn’t saved.'
            : 'The reading change’s outcome is unavailable.';
        check(label.startsWith(expected) && label.includes('Refreshing reading status.')
            && !label.includes('Waiting for'), label);
        check(notice === original && notice.getAttribute('role') === 'status', 'Status region replaced');
        check(result.outcomeKnown === (kind !== 'unavailable')
            && result.success === (kind === 'unavailable' ? undefined : kind === 'success'),
            'Original native outcome changed');
        const button = notice.lastElementChild;
        check(button.hidden && button.disabled, 'Cancel must be unavailable');
        button.click();
        check(controls.length === 0, 'Hidden control cancelled the native change');
        const recovery = coordinator.recoverHistoryReadingStatus({requestID: message.requestID,
            observationToken: message.manualReadPendingObservationToken});
        await Promise.resolve(); completeQuery(true);
        check(await recovery, 'Recovery not acknowledged');
        check(!document.querySelector('.mnb-native-mark-pending'), 'Finished notice retained');
        check(commands.length === 1, 'Mutation replayed');
        return {label, commands: commands.length, controls: controls.length};
    } finally {
        coordinator.close();
        for (const url of urls.values()) URL.revokeObjectURL(url);
    }
}"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=RESOURCES / MODULES[0])
    parser.add_argument("--browser", default=os.environ.get("CHROMIUM_EXECUTABLE"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    sources = {name: (args.source if name == MODULES[0] else RESOURCES / name).read_text()
               for name in MODULES}
    results = []
    with sync_playwright() as playwright:
        launch = {"headless": True}
        if args.browser:
            launch["executable_path"] = args.browser
        browser = playwright.chromium.launch(**launch)
        try:
            for kind in ("success", "failure", "unavailable"):
                for desired in ("marked", "unmarked"):
                    page = browser.new_page()
                    name = f"{desired}: {kind} during status refresh"
                    try:
                        page.set_content("<!doctype html><body></body>")
                        detail = page.evaluate(CASE, {"kind": kind, "desired": desired, "sources": sources})
                        results.append({"case": name, "passed": True, **detail})
                        print(f"PASS {name}")
                    except Exception as error:
                        results.append({"case": name, "passed": False, "error": str(error)})
                        print(f"FAIL {name}: {error}")
                    finally:
                        page.close()
            version = browser.version
        finally:
            browser.close()
    result = {"browser": version, "source_sha256": {
        name: hashlib.sha256(source.encode()).hexdigest() for name, source in sources.items()},
        "passed": sum(case["passed"] for case in results),
        "failed": sum(not case["passed"] for case in results), "cases": results}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"{result['passed']} passed; {result['failed']} failed")
    return int(result["failed"] != 0)


if __name__ == "__main__":
    raise SystemExit(main())
