// Native Go To previews and releases share one renderer-side owner. A retired
// release may finish navigation, but cannot finalize a successor's HUD session.
export const createReaderProgressScrubController = ({ getReader, navigate }) => {
    const readers = new WeakMap();
    const stateFor = reader => {
        let state = readers.get(reader);
        if (!state) {
            state = { active: null, retired: new Set() };
            readers.set(reader, state);
        }
        return state;
    };
    const finish = (reader, cancel) => {
        const hud = reader.navHUD;
        hud?.endProgressScrubSession?.(hud?.getCurrentLocationDescriptor?.() ?? null, { cancel });
    };
    const retireActive = (reader, state) => {
        const active = state.active;
        if (!active) return;
        state.active = null;
        state.retired.add(active.ownerID);
        reader.scheduleGoToFraction?.cancel?.();
        finish(reader, true);
    };
    const begin = (sheetID, ownerID) => {
        const reader = getReader();
        if (!reader || !sheetID || !ownerID) return null;
        const state = stateFor(reader);
        if (state.retired.has(ownerID)) return null;
        if (state.active?.ownerID !== ownerID) {
            retireActive(reader, state);
            state.active = { sheetID, ownerID, release: null };
            const hud = reader.navHUD;
            hud?.beginProgressScrubSession?.(hud?.getCurrentLocationDescriptor?.() ?? null);
        }
        return { reader, state, active: state.active };
    };
    return {
        begin(sheetID, ownerID) {
            return begin(sheetID, ownerID) != null;
        },
        owns(ownerID, reader = getReader()) {
            return !!reader && getReader() === reader
                && readers.get(reader)?.active?.ownerID === ownerID;
        },
        schedule(sheetID, ownerID, fraction) {
            const owner = begin(sheetID, ownerID);
            if (!owner || owner.active.release != null) return false;
            owner.reader.scheduleGoToFraction?.(fraction, ownerID);
            return true;
        },
        retire(ownerIDs) {
            const reader = getReader();
            if (!reader) return false;
            const state = stateFor(reader);
            const owners = new Set(ownerIDs ?? []);
            for (const ownerID of owners) state.retired.add(ownerID);
            if (!owners.has(state.active?.ownerID)) return false;
            retireActive(reader, state);
            return true;
        },
        async end(sheetID, ownerID, fraction, cancel = false) {
            const owner = begin(sheetID, ownerID);
            if (!owner) return false;
            const { reader, state, active } = owner;
            const hud = reader.navHUD;
            reader.scheduleGoToFraction?.cancel?.();
            const release = Symbol();
            active.release = release;
            const isCurrent = () => getReader() === reader
                && state.active === active && active.release === release;
            const numeric = Number(fraction);
            const clamped = Number.isFinite(numeric) ? Math.max(0, Math.min(1, numeric)) : null;
            const finalDescriptor = clamped != null
                ? (hud?._descriptorFromFraction?.(clamped) ?? { fraction: clamped })
                : (hud?.getCurrentLocationDescriptor?.() ?? null);
            const ownership = !cancel && clamped != null && reader.view
                ? hud?.requestExplicitRelocateHistoryMutation?.('scrub-release') : null;
            try {
                if (!cancel && clamped != null && reader.view) {
                    const accepted = await navigate(reader, clamped, ownership?.relocationID ?? null);
                    if (accepted !== true) hud?.cancelExplicitRelocateHistoryMutation?.(ownership);
                }
            } catch (error) {
                hud?.cancelExplicitRelocateHistoryMutation?.(ownership);
                throw error;
            } finally {
                if (isCurrent()) {
                    // Keep the owner until retirement so a late changed binding
                    // can issue another release without reviving a retired owner.
                    hud?.endProgressScrubSession?.(finalDescriptor, {
                        cancel: !!cancel, releaseFraction: clamped,
                    });
                }
            }
            return isCurrent();
        },
    };
};
