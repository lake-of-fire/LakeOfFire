const excludedBlankPointerTargetSelector = [
    'a',
    'button',
    'input',
    'textarea',
    'select',
    '[role="button"]',
    '[contenteditable="true"]',
    'm-m',
    'm-s',
    'm-t',
    'ruby',
    'rt',
].join(', ')

export const excludedEbookBlankPointerTarget = target =>
    target?.closest?.(excludedBlankPointerTargetSelector) ?? null
