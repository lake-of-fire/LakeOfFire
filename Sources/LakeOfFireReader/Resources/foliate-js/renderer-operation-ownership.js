export const rendererOperationSuperseded = (reason = 'renderer-superseded') => ({
    ignored: true,
    reason,
})

export const runCurrentRendererOperation = async ({
    operation,
    isCurrent = () => true,
    supersededReason = 'renderer-superseded',
}) => {
    const superseded = () => rendererOperationSuperseded(supersededReason)
    if (!isCurrent()) return superseded()
    try {
        const value = await operation()
        return isCurrent() ? { ignored: false, value } : superseded()
    } catch (error) {
        if (!isCurrent()) return superseded()
        throw error
    }
}
