// Copyright © Anthony DePasquale

import Testing

@testable import HFAPI

@Suite("ContentLengthSignal")
struct ContentLengthSignalTests {
    @Test("resolve(_:) wakes all parked awaiters with the same value")
    func resolveWakesAwaiters() async {
        let signal = ContentLengthSignal()

        async let a = signal.value
        async let b = signal.value
        async let c = signal.value
        await Task.yield()
        await Task.yield()

        signal.resolve(42)

        let results = await (a, b, c)
        #expect(results.0 == 42)
        #expect(results.1 == 42)
        #expect(results.2 == 42)
    }

    @Test("post-resolve(_:) reads are non-blocking and observe the resolved value")
    func resolveBeforeAwaitIsImmediate() async {
        let signal = ContentLengthSignal()
        signal.resolve(7)
        let v = await signal.value
        #expect(v == 7)
    }

    @Test("second resolve(_:) is a no-op")
    func resolveIsFirstResolutionWins() async {
        let signal = ContentLengthSignal()
        signal.resolve(1)
        signal.resolve(99)
        let v = await signal.value
        #expect(v == 1)
    }
}
