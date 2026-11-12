import assert from 'node:assert/strict'
import test from 'node:test'

import {
    navButtonRefreshIsCurrent,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/nav-button-refresh-ownership.js'

const renderer = {}

const current = overrides => navButtonRefreshIsCurrent({
    capturedRenderer: renderer,
    currentRenderer: renderer,
    capturedOperationSequence: 7,
    currentOperationSequence: 7,
    capturedViewGeneration: 13,
    currentViewGeneration: 13,
    activeOperationCount: 0,
    ...overrides,
})

test('a refresh remains current only while renderer and chapter-operation ownership are unchanged', () => {
    assert.equal(current({}), true)
    assert.equal(current({ closed: true }), false)
    assert.equal(current({ currentRenderer: {} }), false)
    assert.equal(current({ activeOperationCount: 1 }), false)
    assert.equal(current({ currentViewGeneration: 14 }), false)
})

test('a completed newer chapter operation permanently supersedes an older suspended refresh', () => {
    assert.equal(current({
        activeOperationCount: 0,
        currentOperationSequence: 8,
    }), false)
})

test('active-operation cleanup alone cannot restore stale ownership', () => {
    const capturedOperationSequence = 11
    assert.equal(navButtonRefreshIsCurrent({
        capturedRenderer: renderer,
        currentRenderer: renderer,
        capturedOperationSequence,
        currentOperationSequence: capturedOperationSequence,
        activeOperationCount: 1,
    }), false)

    assert.equal(navButtonRefreshIsCurrent({
        capturedRenderer: renderer,
        currentRenderer: renderer,
        capturedOperationSequence,
        currentOperationSequence: capturedOperationSequence + 1,
        activeOperationCount: 0,
    }), false)
})

test('a renderer relocation supersedes a refresh even when the renderer instance is reused', () => {
    assert.equal(current({
        capturedViewGeneration: 21,
        currentViewGeneration: 22,
    }), false)
})
