(() => {
    'use strict';
    const node = document.getElementById('reader-component');
    if (!node || node.textContent.length > 16384) return;
    let config;
    try { config = JSON.parse(node.textContent); } catch (_) { return; }
    let provider;
    try { provider = new URL(config.provider); } catch (_) { return; }
    if (!['http:', 'https:'].includes(provider.protocol) || provider.username || provider.password) return;
    const registration = config.registration;
    if (typeof registration !== 'string' || registration.length !== 36) return;
    let port = null;
    let retired = false;
    const status = document.getElementById('status');
    const frame = document.createElement('iframe');
    frame.title = 'External content';
    frame.allow = typeof config.permissions === 'string' ? config.permissions : 'autoplay; fullscreen; picture-in-picture; encrypted-media';
    frame.allowFullscreen = true;
    if (typeof config.sandbox === 'string') frame.setAttribute('sandbox', config.sandbox);
    frame.referrerPolicy = typeof config.referrerPolicy === 'string' ? config.referrerPolicy : 'strict-origin-when-cross-origin';
    const source = document.getElementById('source');
    source.href = provider.href;
    function report(state) {
        if (!retired && port) port.postMessage({type: state});
    }
    // The normal iframe exists immediately. Provider APIs are never a
    // prerequisite for either the media frame or the offline/source UI.
    frame.addEventListener('load', () => {
        status.textContent = 'External content';
        report('navigation-complete'); // Not a claim of provider functionality.
    });
    frame.addEventListener('error', () => {
        status.textContent = 'External content unavailable. Retry or open source.';
        report('navigation-error');
    });
    frame.src = provider.href;
    document.body.prepend(frame);
    document.getElementById('retry').addEventListener('click', () => {
        status.textContent = 'Loading external content…';
        frame.src = provider.href;
        report('retry');
    });
    const deadline = setTimeout(() => {
        status.textContent = 'If external content is unavailable, retry or open source.';
    }, 10000);
    window.addEventListener('message', event => {
        if (retired || event.source !== parent || !['internal://local', location.origin].includes(event.origin)) return;
        const data = event.data;
        if (!data || data.type !== 'reader-component-port' || data.registration !== registration || event.ports.length !== 1) return;
        port?.close();
        port = event.ports[0];
        // This port is outbound-only. No storage, lookup or article command
        // is accepted from either the provider window or its message channel.
        report('initialized');
    });
    parent.postMessage({type: 'reader-component-initialized', registration}, '*');
    window.addEventListener('pagehide', () => { retired = true; clearTimeout(deadline); port?.close(); }, {once: true});
})();
