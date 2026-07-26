export class ViewHistory extends EventTarget {
    #states = []
    #index = -1

    pushState(state) {
        const last = this.#states[this.#index]
        const repeatsFraction = Number.isFinite(last?.fraction)
            && last.fraction === state?.fraction
        if (last === state || repeatsFraction) return
        this.#states[++this.#index] = state
        this.#states.length = this.#index + 1
        this.dispatchEvent(new Event('index-change'))
    }

    replaceState(state) {
        if (this.#index < 0) {
            this.pushState(state)
            return
        }
        this.#states[this.#index] = state
    }

    back() {
        if (this.#index <= 0) return
        const detail = { state: this.#states[--this.#index] }
        this.dispatchEvent(new CustomEvent('popstate', { detail }))
        this.dispatchEvent(new Event('index-change'))
    }

    forward() {
        if (this.#index >= this.#states.length - 1) return
        const detail = { state: this.#states[++this.#index] }
        this.dispatchEvent(new CustomEvent('popstate', { detail }))
        this.dispatchEvent(new Event('index-change'))
    }

    get canGoBack() {
        return this.#index > 0
    }

    get canGoForward() {
        return this.#index < this.#states.length - 1
    }

    clear() {
        this.#states = []
        this.#index = -1
    }
}
