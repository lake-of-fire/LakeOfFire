export class CacheWarmerPrecedingSections {
    #closed = false
    #finished = false
    #highestSectionIndex = -1
    #requiredTargetIndex = null
    #waiters = new Set()

    get closed() {
        return this.#closed
    }

    get finished() {
        return this.#finished
    }

    get highestSectionIndex() {
        return this.#highestSectionIndex
    }

    get requiredTargetIndex() {
        return this.#requiredTargetIndex
    }

    isComplete(targetIndex) {
        if (!Number.isInteger(targetIndex) || targetIndex <= 0) return true
        return this.#closed
            || this.#finished
            || this.#highestSectionIndex >= targetIndex - 1
    }

    waitFor(targetIndex) {
        if (this.isComplete(targetIndex)) return Promise.resolve()
        this.#requiredTargetIndex = Math.max(this.#requiredTargetIndex ?? 0, targetIndex)
        return new Promise(resolve => {
            this.#waiters.add({ targetIndex, resolve })
        })
    }

    resetProgress() {
        if (this.#closed) return false
        this.#finished = false
        this.#highestSectionIndex = -1
        return true
    }

    recordLoadedSection(sectionIndex) {
        if (this.#closed || !Number.isInteger(sectionIndex)) return false
        this.#highestSectionIndex = Math.max(this.#highestSectionIndex, sectionIndex)
        this.#resolveCompletedWaiters()
        return true
    }

    finish() {
        if (this.#closed || this.#finished) return false
        this.#finished = true
        this.#resolveCompletedWaiters()
        return true
    }

    close() {
        if (this.#closed) return false
        this.#closed = true
        this.#resolveAllWaiters()
        return true
    }

    #resolveCompletedWaiters() {
        for (const waiter of this.#waiters) {
            if (!this.isComplete(waiter.targetIndex)) continue
            this.#waiters.delete(waiter)
            waiter.resolve()
        }
        this.#refreshRequiredTargetIndex()
    }

    #resolveAllWaiters() {
        for (const waiter of this.#waiters) waiter.resolve()
        this.#waiters.clear()
        this.#requiredTargetIndex = null
    }

    #refreshRequiredTargetIndex() {
        let requiredTargetIndex = null
        for (const waiter of this.#waiters) {
            requiredTargetIndex = Math.max(requiredTargetIndex ?? 0, waiter.targetIndex)
        }
        this.#requiredTargetIndex = requiredTargetIndex
    }
}
