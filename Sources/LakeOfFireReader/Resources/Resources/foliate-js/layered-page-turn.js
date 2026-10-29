// Adapted from manabi-reader-web's Foliate slide-geometry/PageTurnController
// (6d886361). Copyright (c) 2026, ッツ Reader Authors. All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

export function slideGeometry(value, turn, reading, width) {
    const progress = Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0
    const extent = Number.isFinite(width) ? Math.max(0, width) : 0
    const sign = reading === 'rtl' ? 1 : -1
    return {
        progress,
        currentX: sign * extent * (turn === 1 ? progress : -0.15 * progress),
        neighborX: sign * extent * (turn === 1 ? -0.15 * (1 - progress) : 1 - progress),
        currentShade: turn === -1 ? 0.24 * progress : 0,
        neighborShade: turn === 1 ? 0.24 * (1 - progress) : 0,
    }
}

export function wheelPageDistance(x, y, mode, width, reading) {
    const horizontal = Math.abs(x) >= Math.abs(y)
    const pixels = (horizontal ? x : y) * (mode === 1 ? 16 : mode === 2 ? width : 1)
    return pixels * (horizontal && reading === 'rtl' ? -1 : 1)
}

// Preparation only paints; the renderer's existing navigation transaction owns
// the eventual commit. Every pending callback is fenced by this generation.
export class LayeredPageTurnController {
    constructor(renderer, environment = globalThis) {
        this.renderer = renderer
        this.env = environment
        this.lifetime = new AbortController()
        this.generation = 0
        this.progress = 0
        this.direction = 1
        this.suppressClickUntil = 0
        this.bind(renderer, this.lifetime.signal)
        renderer.addEventListener('document-committed', () => this.bindDocument(), { signal: this.lifetime.signal })
        // An unclaimed mouse press has no capture. Its release can land on
        // surrounding chrome instead of either reader input surface.
        const releaseUnclaimedPointer = event => {
            if (this.pointer?.id === event.pointerId && !this.pointer.claimed) this.releasePointer()
        }
        for (const type of ['pointerup', 'pointercancel']) {
            this.env.document.addEventListener(type, releaseUnclaimedPointer,
                { signal: this.lifetime.signal, capture: true })
        }
        this.env.addEventListener('blur', () => this.cancel(), { signal: this.lifetime.signal })
        this.env.addEventListener('resize', () => this.cancel(), { signal: this.lifetime.signal })
        this.env.document.addEventListener('visibilitychange', () => {
            if (this.env.document.hidden) this.cancel()
        }, { signal: this.lifetime.signal })
        this.bindDocument()
    }

    get active() { return !!(this.pending || this.prepared || this.committing) }
    width() { return Math.max(1, this.renderer.getBoundingClientRect().width) }
    selected() { return !!this.renderer.getContents()[0]?.doc?.getSelection()?.toString() }
    inputControl(target) {
        return !!target?.closest?.('button, input, textarea, select, [contenteditable], video, audio')
    }
    capturePointer(target, pointerId) {
        // A pointer can be cancelled between event delivery and capture.
        try { target.setPointerCapture?.(pointerId) } catch (_error) {}
    }
    releasePointer() {
        const pointer = this.pointer
        // Clear ownership first: releasing capture can deliver a loss event.
        this.pointer = undefined
        try {
            if (pointer?.target?.hasPointerCapture?.(pointer.id)) {
                pointer.target.releasePointerCapture(pointer.id)
            }
        } catch (_error) {}
    }
    point(event) {
        const frame = event.target?.ownerDocument?.defaultView?.frameElement
        const rect = frame?.getBoundingClientRect()
        return { x: event.clientX + (rect?.left ?? 0), y: event.clientY + (rect?.top ?? 0) }
    }
    pointerProgress(pointer, event) {
        const sign = this.renderer.pageTurnDirection === 'rtl' ? 1 : -1
        return pointer.base + sign * (this.point(event).x - pointer.x) / this.width()
    }
    settle(commit) {
        // Pointer/wheel listeners have no caller to receive a navigation error.
        // finish publishes it; explicit turn() callers also receive rejection.
        void this.finish(commit).catch(() => {})
    }
    bindDocument() {
        this.documentEvents?.abort()
        this.documentEvents = new AbortController()
        const doc = this.renderer.getContents()[0]?.doc
        if (doc) {
            const previous = doc.documentElement.style.touchAction
            doc.documentElement.style.touchAction = 'pan-y pinch-zoom'
            this.documentEvents.signal.addEventListener('abort', () => {
                doc.documentElement.style.touchAction = previous
            }, { once: true })
            this.bind(doc, this.documentEvents.signal)
        }
    }
    bind(target, signal) {
        target.addEventListener('pointerdown', event => {
            if (!event.isPrimary) { this.cancel(); return }
            this.suppressClickUntil = 0
            if (event.button !== 0 || this.committing || this.renderer.scrolled || this.renderer.navigationInFlight
                || this.inputControl(event.target) || this.selected()
                || (this.env.visualViewport?.scale ?? 1) > 1) return
            // Mouse text drags remain native; margins can turn the page.
            if (event.pointerType === 'mouse' && target.nodeType === 9) return
            // Catch the currently painted pose, including a snap-back animation.
            this.interrupt()
            const point = this.point(event)
            this.pointer = { id: event.pointerId, ...point, time: event.timeStamp,
                base: this.direction * this.progress, claimed: this.active, target: event.target }
            if (this.pointer.claimed) this.capturePointer(event.target, event.pointerId)
        }, { signal })
        target.addEventListener('pointermove', event => {
            const pointer = this.pointer
            if (!pointer || pointer.id !== event.pointerId) return
            const point = this.point(event)
            const dx = point.x - pointer.x
            const dy = point.y - pointer.y
            if (!pointer.claimed) {
                if (Math.hypot(dx, dy) < 8) return
                if (event.timeStamp - pointer.time > 350 || Math.abs(dy) > Math.abs(dx) || this.selected()) {
                    this.pointer = undefined
                    return
                }
                pointer.claimed = true
                this.capturePointer(pointer.target, event.pointerId)
            }
            event.preventDefault()
            this.move(this.pointerProgress(pointer, event))
        }, { signal, passive: false })
        target.addEventListener('pointerup', event => {
            const pointer = this.pointer
            if (!pointer || pointer.id !== event.pointerId) return
            this.releasePointer()
            if (pointer.claimed) {
                // A final coalesced movement need not arrive as pointermove.
                this.move(this.pointerProgress(pointer, event))
                this.suppressClickUntil = this.env.performance.now() + 500
                this.settle(this.progress >= 0.5)
            }
        }, { signal })
        const cancelOwnedPointer = event => {
            if (this.pointer?.id === event.pointerId) this.cancel()
        }
        target.addEventListener('pointercancel', cancelOwnedPointer, { signal })
        target.addEventListener('lostpointercapture', event => {
            const pointer = this.pointer
            // Touch implicitly captures the actual paper node. Claiming it on
            // the retargeted shadow host then emits loss from that old node.
            // Keep the drag if our current target still owns the capture.
            if (pointer?.id === event.pointerId
                && !pointer.target.hasPointerCapture?.(pointer.id)) this.cancel()
        }, { signal })
        target.addEventListener('touchstart', event => {
            if (event.touches.length > 1) this.cancel()
        }, { signal, passive: true })
        target.addEventListener('click', event => {
            if (this.env.performance.now() < this.suppressClickUntil) {
                this.suppressClickUntil = 0
                event.preventDefault()
                event.stopImmediatePropagation()
            }
        }, { signal, capture: true })
        target.addEventListener('wheel', event => {
            if (event.ctrlKey || event.metaKey || event.defaultPrevented || this.inputControl(event.target)
                || this.selected() || this.pointer || this.committing || this.renderer.scrolled || this.renderer.navigationInFlight
                || (this.env.visualViewport?.scale ?? 1) > 1) return
            const delta = wheelPageDistance(event.deltaX, event.deltaY, event.deltaMode,
                this.width(), this.renderer.pageTurnDirection)
            if (!Number.isFinite(delta) || delta === 0) return
            event.preventDefault()
            this.interrupt()
            this.move(this.direction * this.progress + delta / this.width())
            this.env.clearTimeout(this.wheelTimer)
            this.wheelTimer = this.env.setTimeout(() => this.settle(this.progress >= 0.5), 180)
        }, { signal, passive: false })
    }
    move(signed) {
        const direction = signed < 0 ? -1 : 1
        if (direction !== this.direction) this.resetTurn()
        this.direction = direction
        this.progress = Math.min(1, Math.abs(signed))
        if (!this.pending && !this.prepared) {
            const generation = this.generation
            this.pending = Promise.resolve(this.renderer.preparePageTurn(direction)).then(turn => {
                if (generation !== this.generation) { turn?.cancel(); return null }
                this.prepared = turn
                turn?.update(this.progress)
                return turn
            }).catch(error => {
                if (generation === this.generation) {
                    this.cancel()
                    this.renderer.dispatchEvent(new CustomEvent('pageturnerror', { detail: error }))
                }
                return null
            })
        }
        this.prepared?.update(this.progress)
    }
    interrupt() {
        this.env.cancelAnimationFrame(this.frame)
        this.env.clearTimeout(this.wheelTimer)
        this.animation = (this.animation ?? 0) + 1
        this.settling = false
        this.resolvePendingFinish?.(null)
        this.resolvePendingFinish = null
        // Once the renderer starts its transaction, cancelling the visual
        // preview cannot change that transaction's eventual movement receipt.
        if (!this.committing) this.resolveFinish?.(false)
        this.resolveFinish = null
    }
    async turn(direction, options = {}) {
        // Selection blocks gesture admission, not an explicit navigation
        // command. Lookup boundary turns retain it until movement is proven.
        if (this.active || this.pointer) return { ignored: true, reason: 'pageTurnInFlight' }
        this.move(direction * 0.001)
        return this.finish(true, options)
    }
    async finish(commit, options = {}) {
        if (this.settling || this.committing) return false
        this.settling = true
        const generation = this.generation
        const animation = this.animation = (this.animation ?? 0) + 1
        this.env.clearTimeout(this.wheelTimer)
        const prepared = this.prepared ?? await Promise.race([
            this.pending,
            new Promise(resolve => { this.resolvePendingFinish = resolve }),
        ])
        if (generation !== this.generation || animation !== this.animation) return false
        this.resolvePendingFinish = null
        if (!prepared) { this.cancel(); return false }
        const start = this.progress
        const end = commit ? 1 : 0
        const reduced = prepared.instant === true || this.env.matchMedia('(prefers-reduced-motion: reduce)').matches
        const started = this.env.performance.now()
        return new Promise((resolve, reject) => {
            this.resolveFinish = resolve
            const step = async now => {
                if (generation !== this.generation || animation !== this.animation) return
                let finished = false
                let commitStarted = false
                try {
                    const t = reduced || this.env.document.hidden ? 1 : Math.min(1, (now - started) / 220)
                    this.progress = start + (end - start) * (1 - (1 - t) ** 3)
                    if (prepared.update(this.progress) === false) {
                        finished = true
                        resolve(false)
                    } else if (t < 1) this.frame = this.env.requestAnimationFrame(step)
                    else {
                        finished = true
                        this.committing = commitStarted = commit
                        resolve(commit ? await prepared.commit(options) : false)
                    }
                } catch (error) {
                    finished = true
                    this.renderer.dispatchEvent(new CustomEvent('pageturnerror', { detail: error }))
                    // A commit may fail after movement. Preserve that error so
                    // the reader's normal transaction can classify the result.
                    if (commitStarted) reject(error)
                    else resolve(false)
                } finally {
                    if (finished) {
                        this.committing = false
                        if (generation === this.generation) this.resetTurn()
                    }
                }
            }
            this.frame = this.env.requestAnimationFrame(step)
        })
    }
    resetTurn() {
        this.generation += 1
        this.interrupt()
        this.renderer.cancelPageTurn(!this.committing)
        this.prepared = null
        this.pending = null
        this.progress = 0
    }
    cancel() { this.releasePointer(); this.resetTurn() }
    destroy() {
        this.cancel()
        this.lifetime.abort()
        this.documentEvents?.abort()
    }
}
