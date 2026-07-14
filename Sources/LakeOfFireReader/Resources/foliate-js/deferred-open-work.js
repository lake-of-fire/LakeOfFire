export class DeferredOpenWorkCoordinator {
    #generation = 0
    #scheduledGeneration = null
    #scheduledPromise = null
    #timer = null
    #cancelTask = null
    #resolveScheduled = null

    beginGeneration() {
        this.cancel()
        this.#generation += 1
        return this.#generation
    }

    isCurrent(generation) {
        return generation === this.#generation
    }

    schedule(generation, tasks, {
        isOwnerCurrent = () => true,
        onError = () => {},
        scheduleTask = callback => setTimeout(callback, 0),
        cancelTask = handle => clearTimeout(handle),
    } = {}) {
        if (!this.#isCurrent(generation, isOwnerCurrent)) {
            return Promise.resolve(false)
        }
        if (this.#scheduledGeneration === generation && this.#scheduledPromise) {
            return this.#scheduledPromise
        }

        this.#scheduledGeneration = generation
        this.#cancelTask = cancelTask
        this.#scheduledPromise = new Promise(resolve => {
            this.#resolveScheduled = resolve
            this.#timer = scheduleTask(async () => {
                this.#timer = null
                let completed = false
                try {
                    for (const task of tasks) {
                        if (!this.#isCurrent(generation, isOwnerCurrent)) {
                            return
                        }
                        try {
                            await task.run({
                                isCurrent: () => this.#isCurrent(generation, isOwnerCurrent),
                            })
                        } catch (error) {
                            onError(task.name, error)
                        }
                    }
                    completed = this.#isCurrent(generation, isOwnerCurrent)
                } finally {
                    if (this.#scheduledGeneration === generation) {
                        this.#scheduledGeneration = null
                        this.#scheduledPromise = null
                        this.#cancelTask = null
                        this.#resolveScheduled = null
                    }
                    resolve(completed)
                }
            })
        })
        return this.#scheduledPromise
    }

    cancel() {
        if (this.#timer !== null) {
            this.#cancelTask?.(this.#timer)
            this.#timer = null
        }
        this.#cancelTask = null
        this.#resolveScheduled?.(false)
        this.#resolveScheduled = null
        this.#scheduledGeneration = null
        this.#scheduledPromise = null
    }

    #isCurrent(generation, isOwnerCurrent) {
        return this.isCurrent(generation) && isOwnerCurrent()
    }
}
