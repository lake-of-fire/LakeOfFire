const byteView = value => {
    if (value instanceof Uint8Array) return value
    if (ArrayBuffer.isView(value)) {
        return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
    }
    return new Uint8Array(value)
}

const normalizedEncodingLabel = value => {
    if (typeof value !== 'string') return null
    const trimmed = value.trim()
    if (!trimmed) return null
    if ((trimmed.startsWith('"') && trimmed.endsWith('"'))
        || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
        return trimmed.slice(1, -1).trim() || null
    }
    return trimmed
}

const detectedEPUBTextEncoding = bytes => {
    if (bytes.length >= 3
        && bytes[0] === 0xEF
        && bytes[1] === 0xBB
        && bytes[2] === 0xBF) {
        return 'utf-8'
    }
    if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
        return 'utf-16le'
    }
    if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
        return 'utf-16be'
    }
    if (bytes.length >= 4) {
        if (bytes[1] === 0x00
            && bytes[3] === 0x00
            && (bytes[0] !== 0x00 || bytes[2] !== 0x00)) {
            return 'utf-16le'
        }
        if (bytes[0] === 0x00
            && bytes[2] === 0x00
            && (bytes[1] !== 0x00 || bytes[3] !== 0x00)) {
            return 'utf-16be'
        }
    }
    return 'utf-8'
}

const decoderForLabel = label => {
    try {
        return new TextDecoder(label)
    } catch (_error) {
        return null
    }
}

export const decodeEPUBTextBytes = (value, { declaredEncoding = null } = {}) => {
    const bytes = byteView(value)
    const detectedEncoding = detectedEPUBTextEncoding(bytes)
    const decoder = decoderForLabel(normalizedEncodingLabel(declaredEncoding))
        ?? decoderForLabel(detectedEncoding)
        ?? new TextDecoder('utf-8')
    return decoder.decode(bytes)
}
