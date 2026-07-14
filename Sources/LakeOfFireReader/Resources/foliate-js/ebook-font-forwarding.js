export const copyCustomReaderFontStyleToDocument = (
    sourceFontStyle,
    doc,
    reason = 'unknown',
    fontFamilies = globalThis,
) => {
    if (!doc || !sourceFontStyle) return false;

    let targetFontStyle = doc.getElementById('mnb-custom-fonts-inline');
    const sourceTag = sourceFontStyle.tagName?.toLowerCase();
    const desiredTag = sourceTag === 'link' ? 'link' : 'style';
    if (targetFontStyle && targetFontStyle.tagName?.toLowerCase() !== desiredTag) {
        targetFontStyle.remove();
        targetFontStyle = null;
    }
    if (!targetFontStyle) {
        targetFontStyle = doc.createElement(desiredTag);
        targetFontStyle.id = 'mnb-custom-fonts-inline';
        (doc.head || doc.documentElement).appendChild(targetFontStyle);
    }

    let changed = false;
    const writingDirection = doc.body?.dataset?.mnbWritingDirection
        || doc.body?.dataset?.mnbFoliateWritingDirection
        || null;
    const isVerticalDocument = writingDirection === 'vertical'
        || doc.body?.classList?.contains?.('reader-vertical-writing') === true;
    const directionalFamily = isVerticalDocument
        ? (fontFamilies.manabiVerticalFontFamilyName || sourceFontStyle.dataset?.mnbInjectedFontFamily)
        : (fontFamilies.manabiHorizontalFontFamilyName || sourceFontStyle.dataset?.mnbInjectedFontFamily);

    if (desiredTag === 'link') {
        const nextRel = sourceFontStyle.rel || 'stylesheet';
        if (targetFontStyle.rel !== nextRel) {
            targetFontStyle.rel = nextRel;
            changed = true;
        }
        if (targetFontStyle.href !== sourceFontStyle.href) {
            targetFontStyle.href = sourceFontStyle.href;
            changed = true;
        }
    } else {
        const nextText = sourceFontStyle.textContent || '';
        if (targetFontStyle.textContent !== nextText) {
            targetFontStyle.textContent = nextText;
            changed = true;
        }
    }

    for (const [key, value] of Object.entries(sourceFontStyle.dataset || {})) {
        const nextValue = key === 'mnbInjectedFontFamily' && directionalFamily
            ? directionalFamily
            : value;
        if (targetFontStyle.dataset[key] !== nextValue) {
            targetFontStyle.dataset[key] = nextValue;
            changed = true;
        }
    }
    if (doc.documentElement && directionalFamily) {
        if (doc.documentElement.dataset.mnbInjectedFontFamily !== directionalFamily) {
            doc.documentElement.dataset.mnbInjectedFontFamily = directionalFamily;
            changed = true;
        }
        if (doc.documentElement.dataset.mnbFontInjected !== '1') {
            doc.documentElement.dataset.mnbFontInjected = '1';
            changed = true;
        }
    }
    return changed;
};
