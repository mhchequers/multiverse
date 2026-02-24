import Foundation
import SwiftTerm

class MonitoredTerminalView: LocalProcessTerminalView {
    private(set) var lastOutputTime: Date?
    private(set) var isProcessRunning = true

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        DispatchQueue.main.async {
            self.lastOutputTime = Date()
        }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        DispatchQueue.main.async {
            self.isProcessRunning = false
        }
    }

    func terminateProcessGroup() {
        let pid = process.shellPid
        guard pid != 0 else { return }
        kill(pid, SIGHUP)
        terminate()
    }
}
