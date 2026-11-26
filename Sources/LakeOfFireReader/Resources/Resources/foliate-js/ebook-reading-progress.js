const clampedFiniteFraction = value => {
    if (typeof value !== 'number' || !Number.isFinite(value)) return null
    return Math.max(0, Math.min(1, value))
}

export const ebookProgressFractionForRelocate = ({
    relocateFraction,
    authoritativeFraction,
    progressUnavailable,
}) => progressUnavailable === true
    ? null
    : clampedFiniteFraction(relocateFraction) ?? clampedFiniteFraction(authoritativeFraction)
