import Testing
@testable import Hotkey

@Suite("ActivationStateMachine smoke")
struct ActivationStateMachineSmokeTests {
    @Test("state machine constructs and resets without crashing")
    func smoke() async {
        let fsm = ActivationStateMachine()
        let outputs = await fsm.handle(.timerExpired)
        #expect(outputs.isEmpty)
        await fsm.reset()
    }
}
