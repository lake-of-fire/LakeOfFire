export const ebookLayoutSettingDatasetKeys = Object.freeze([
    'mnbFuriganaEnabled',
    'mnbFuriganaOriginalOnly',
    'mnbRomajiModeEnabled',
    'mnbFamiliarFuriganaEnabled',
    'mnbLearningFuriganaEnabled',
    'mnbKnownFuriganaEnabled',
]);

export const applyLayoutSettingsToEbookDocument = (sourceDocument, targetDocument) => {
    const sourceDataset = sourceDocument?.body?.dataset;
    const targetDataset = targetDocument?.body?.dataset;
    if (!sourceDataset || !targetDataset || sourceDocument === targetDocument) {
        return false;
    }
    let changed = false;
    for (const key of ebookLayoutSettingDatasetKeys) {
        const value = sourceDataset[key];
        if (value === undefined || targetDataset[key] === value) {
            continue;
        }
        targetDataset[key] = value;
        changed = true;
    }
    return changed;
};
