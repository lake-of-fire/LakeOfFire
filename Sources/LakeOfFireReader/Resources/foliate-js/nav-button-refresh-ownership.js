export const navButtonRefreshIsCurrent = ({
    closed = false,
    capturedRenderer = null,
    currentRenderer = null,
    capturedOperationSequence = 0,
    currentOperationSequence = 0,
    capturedViewGeneration = 0,
    currentViewGeneration = 0,
    activeOperationCount = 0,
} = {}) => (
    closed !== true
    && capturedRenderer != null
    && capturedRenderer === currentRenderer
    && capturedOperationSequence === currentOperationSequence
    && capturedViewGeneration === currentViewGeneration
    && activeOperationCount === 0
)
