// ADBLXTests/Features/UpdateProgress/UpdateProgressModelTests.swift
import Testing
@testable import ADBLX

@Suite("UpdateProgressModel")
struct UpdateProgressModelTests {
    @Test("starts in the idle phase")
    func startsIdle() {
        let model = UpdateProgressModel()
        #expect(model.phase == .idle)
    }

    @Test("start() walks through checking, downloading, installing, then complete")
    func startWalksThroughPhases() async {
        let model = UpdateProgressModel()

        await model.start()

        #expect(model.phase == .complete)
    }

    @Test("progressDescription reflects the current phase")
    func progressDescriptionReflectsPhase() {
        let model = UpdateProgressModel()
        model.phase = .downloading
        #expect(model.progressDescription == "Downloading filter updates…")
    }
}
