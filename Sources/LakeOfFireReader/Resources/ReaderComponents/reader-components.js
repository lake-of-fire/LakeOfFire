(() => {
    'use strict';
    const node = document.getElementById('mnb-reader-components');
    if (!node || node.textContent.length > 1048576) return;
    let config;
    try { config = JSON.parse(node.textContent); } catch (_) { return; }
    if (!Array.isArray(config.embeds) || config.embeds.length > 512) return;
    const records = new Map();
    let retired = false;
    function current() {
        const generation = document.documentElement.dataset.mnbReaderRenderGeneration;
        return !retired && (!generation || generation === config.generation);
    }
    function report(record, stage) {
        if (!current()) return;
        // Only the main Reader document has native privileges. Nested static
        // content keeps its local status and uses no native bridge.
        if (location.protocol === 'internal:' && window === top) {
            window.webkit?.messageHandlers?.readerEmbedState?.postMessage({
                generation: config.generation, registration: record.registration, stage
            });
        }
    }
    async function resolve(record) {
        const attempt = ++record.attempt;
        record.port?.close(); record.port = null; record.origin = null;
        const abort = new AbortController();
        record.abort?.abort(); record.abort = abort;
        const timer = setTimeout(() => abort.abort(), 6000);
        let phase = 'resolver-fetch-failed';
        try {
            const reply = await fetch(record.resolve, {signal: abort.signal, cache: 'no-store'});
            phase = 'resolver-response-failed';
            if (!reply.ok) throw new Error('unavailable');
            const text = await reply.text();
            phase = 'resolver-data-invalid';
            if (text.length > 1024) throw new Error('invalid');
            const url = new URL(JSON.parse(text).url);
            if (!current() || record.attempt !== attempt) return;
            if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || url.username || url.password || url.search || url.hash ||
                !['/embed/' + record.registration, '/inline/' + record.registration].includes(url.pathname)) throw new Error('invalid');
            record.origin = url.origin;
            record.frame.src = url.href;
            record.status.textContent = '';
            report(record, 'dispatched');
        } catch (_) {
            if (current() && record.attempt === attempt) {
                record.status.textContent = 'External content unavailable. Retry or open its source link.';
                report(record, phase);
                report(record, 'unavailable');
            }
        } finally { clearTimeout(timer); }
    }
    for (const item of config.embeds) {
        if (!item || typeof item.registration !== 'string' || item.registration.length !== 36 || typeof item.element !== 'string' || typeof item.resolve !== 'string') continue;
        const frame = document.getElementById(item.element);
        if (!frame || frame.tagName !== 'IFRAME') continue;
        const status = document.createElement('span');
        status.className = 'mnb-component-status';
        const retry = document.createElement('button');
        retry.type = 'button'; retry.textContent = 'Retry embedded content';
        frame.after(status, retry);
        const record = {...item, frame, status, attempt: 0, origin: null, port: null, abort: null};
        records.set(item.registration, record);
        retry.addEventListener('click', () => { if (current()) resolve(record); });
        resolve(record);
    }
    // Swift emits these targets. No document-wide media or metadata scan is
    // needed, and remote media never participates in article readiness.
    if (Array.isArray(config.media) && config.media.length <= 512) {
        for (const item of config.media) {
            if (!item || typeof item.element !== 'string' || typeof item.registration !== 'string' || item.registration.length !== 36) continue;
            const element = document.getElementById(item.element);
            if (!element || !['AUDIO', 'VIDEO'].includes(element.tagName)) continue;
            const status = document.createElement('span');
            status.className = 'mnb-component-status';
            status.setAttribute('role', 'status');
            element.after(status);
            let advanced = false;
            let startedAt = null;
            function update(stage) {
                if (!current()) return;
                if (stage === 'media-error') status.textContent = 'Media unavailable. Open its source link.';
                if (stage === 'media-playing') { status.textContent = ''; startedAt ??= element.currentTime; }
                report(item, stage);
            }
            for (const [event, stage] of [['playing','media-playing'], ['pause','media-paused'], ['ended','media-ended'], ['error','media-error']]) {
                element.addEventListener(event, () => update(stage));
            }
            element.addEventListener('timeupdate', () => {
                if (!advanced && !element.paused && startedAt !== null && element.currentTime - startedAt >= 0.5) {
                    advanced = true; update('media-advanced');
                }
            });
            update(element.error ? 'media-error' : 'media-initialized');
        }
    }
    window.addEventListener('message', event => {
        if (!current() || !event.data || event.data.type !== 'reader-component-initialized') return;
        const record = records.get(event.data.registration);
        if (!record || event.source !== record.frame.contentWindow || event.origin !== record.origin) return;
        record.port?.close();
        const channel = new MessageChannel();
        record.port = channel.port1;
        const attempt = record.attempt;
        let messages = 0;
        channel.port1.onmessage = event => {
            if (!current() || record.attempt !== attempt || ++messages > 128) { channel.port1.close(); return; }
            const value = event.data;
            if (!value || Object.keys(value).length !== 1 || !['initialized', 'navigation-complete', 'navigation-error', 'retry'].includes(value.type)) return;
            report(record, value.type);
        };
        record.frame.contentWindow.postMessage({type: 'reader-component-port', registration: record.registration}, record.origin, [channel.port2]);
    });
    window.addEventListener('pagehide', () => {
        retired = true;
        for (const record of records.values()) { record.abort?.abort(); record.port?.close(); }
    }, {once: true});
})();
