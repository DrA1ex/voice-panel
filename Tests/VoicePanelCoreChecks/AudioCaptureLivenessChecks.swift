import VoicePanelCore

let audioCaptureLivenessChecks: [CheckCase] = [
    CheckCase(name: "Input start without callbacks times out") {
        var input = AudioCaptureLiveness()
        try expectEqual(input.status(at: 10), .inactive)
        input.start(at: 10)
        try expectEqual(input.status(at: 10.99), .waitingForFirstBuffer)
        try expectEqual(input.status(at: 11), .stalled)
    },
    CheckCase(name: "Silent PCM buffers keep input alive but missing buffers do not") {
        var input = AudioCaptureLiveness()
        input.start(at: 0)
        // Buffer delivery, regardless of amplitude or VAD classification, is
        // the signal. A quiet room must never trigger a microphone restart.
        for time in 1...100 {
            input.receivedBuffer(at: Double(time))
            try expectEqual(input.status(at: Double(time) + 0.25), .receiving)
        }
        try expectEqual(input.status(at: 102), .stalled)
    },
    CheckCase(name: "Reconnect requires a new buffer and accepts delayed input") {
        var input = AudioCaptureLiveness()
        input.start(at: 0)
        input.receivedBuffer(at: 0.1)
        input.suspend()
        input.start(at: 5)
        try expectEqual(input.status(at: 5.1), .waitingForFirstBuffer)
        try expectEqual(input.status(at: 6), .stalled)
        input.receivedBuffer(at: 6.2)
        try expectEqual(input.status(at: 6.2), .receiving)
    },
    CheckCase(name: "Deferred stop and late callbacks never reopen a paused input") {
        var input = AudioCaptureLiveness()
        input.start(at: 0)
        input.receivedBuffer(at: 0.1)
        input.suspend()
        input.receivedBuffer(at: 0.2)
        try expectEqual(input.status(at: 100), .inactive)
        input.start(at: 101)
        try expectEqual(input.status(at: 101), .waitingForFirstBuffer)
    },
]
