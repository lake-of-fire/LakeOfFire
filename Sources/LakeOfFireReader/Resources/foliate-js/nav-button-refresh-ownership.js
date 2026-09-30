export const navButtonRefreshIsCurrent = ({
    closed = false,
    capturedRenderer = null,
    currentRenderer = null,
    capturedOperationSequence = 0,
    currentOperationSequence = 0,
    activeOperationCount = 0,
} = {}) => (
    closed !== true
    && capturedRenderer != null
    && capturedRenderer === currentRenderer
    && capturedOperationSequence === currentOperationSequence
    && activeOperationCount === 0
)
