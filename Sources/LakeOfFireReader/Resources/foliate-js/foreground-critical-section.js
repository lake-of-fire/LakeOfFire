export class ForegroundCriticalSectionCoordinator {
    #activeTokens = new Set()
    #cancelTimeout
    #nextSequence = 0
    #postMessage
    #scheduleTimeout
    #timeoutByToken = new Map()
    #timeoutMilliseconds

    constructor({
        postMessage = () => {},
        scheduleTimeout = (callback, delay) => setTimeout(callback, delay),
        cancelTimeout = handle => clearTimeout(handle),
        timeoutMilliseconds = 60_000,
    } = {}) {
        this.#postMessage = postMessage
        this.#scheduleTimeout = scheduleTimeout
        this.#cancelTimeout = cancelTimeout
        this.#timeoutMilliseconds = Math.max(1, Number(timeoutMilliseconds) || 60_000)
    }

    begin() {
        const token = `foreground-${++this.#nextSequence}`
        this.#activeTokens.add(token)
        this.#postMessage({ phase: 'begin', token })
        const timeout = this.#scheduleTimeout(() => this.finish(token), this.#timeoutMilliseconds)
        this.#timeoutByToken.set(token, timeout)
        return token
    }

    finish(token) {
        if (typeof token !== 'string' || !this.#activeTokens.delete(token)) {
            return false
        }
        const timeout = this.#timeoutByToken.get(token)
        this.#timeoutByToken.delete(token)
        if (timeout !== undefined && timeout !== null) {
            this.#cancelTimeout(timeout)
        }
        this.#postMessage({ phase: 'end', token })
        return true
    }

    finishAll() {
        for (const token of Array.from(this.#activeTokens)) {
            this.finish(token)
        }
    }

    get activeCount() {
        return this.#activeTokens.size
    }
}
