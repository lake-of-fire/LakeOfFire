// A full ordered native publication replaces the local Mark overlay. Ordinary
// incremental Mark acknowledgements still use the existing merge path.
export const applyBookReadingProjection = (reader, state, apply) => {
    reader.optimisticReadSegmentIdentifiers.clear()
    reader.optimisticSentenceIdentifiersRead.clear()
    return apply({ ...reader.articleReadingProgress,
        readSegmentIdentifiers: state.readSegmentIdentifiers,
        sentenceIdentifiersRead: state.sentenceIdentifiersRead,
        articleMarkedAsFinished: state.finished })
}
