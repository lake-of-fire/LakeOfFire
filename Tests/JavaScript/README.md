# Reader system-font checks

Run the focused production-behavior suites with Node 24:

```sh
node Tests/JavaScript/ebook-font-forwarding.test.mjs
NODE_PATH=/path/to/external/node_modules \
node Tests/JavaScript/reader-system-font-injection.test.cjs
```

The injection suite requires an external installation of jsdom 26.1.0. It extracts the two JavaScript literals in `ReaderModeViewModel.injectSharedFontIfNeeded`, decodes Swift's escaped backslashes, and executes them against real jsdom documents with controlled font readiness, timers and blob URLs. It checks that system stylesheet requests use an admitted asset family independently of explicit user choices, preserves both font-face aliases, and retains the existing file-asset and readiness behavior.

The forwarding suite imports the production helper and renderer-document selector. DOM/CSS events, font readiness, and viewer snapshot storage are controlled. The paired Core `reader-system-font-producer.test.cjs` additionally exercises the actual Core embedded producer through the viewer forwarding entry point.

These are JavaScript checks, not Swift compilation, URL scheme serving, actual OS font installation or browser layout. `SharedReaderFontTests.swift` retains file-backed coverage and adds system-only CSS, unsupported/missing mapping, identity and quoting regressions; native execution and mounted WebView qualification remain separate.
