import Foundation

final class PTYRegistry {
    private var processes: [String: PTYProcess] = [:]
    private var pidToPaneID: [pid_t: String] = [:]
    private var clients: [ObjectIdentifier: ClientSession] = [:]
    private let lock = NSLock()

    // MARK: - Client lifecycle

    func addClient(_ client: ClientSession) {
        lock.lock()
        clients[ObjectIdentifier(client)] = client
        lock.unlock()
    }

    func removeClient(_ client: ClientSession) {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(client))
        let procs = Array(processes.values)
        lock.unlock()

        for proc in procs {
            proc.removeSubscriber(client)
        }
    }

    // MARK: - Command dispatch

    func handle(_ req: DaemonRequest, client: ClientSession) {
        switch req {
        case .create(let params):
            let paneID = UUID().uuidString
            do {
                let proc = try PTYProcess(
                    paneID: paneID,
                    stableID: params.stableID,
                    cmd: params.cmd,
                    cwd: params.cwd,
                    env: params.env,
                    cols: params.cols,
                    rows: params.rows
                )
                lock.lock()
                processes[paneID] = proc
                pidToPaneID[proc.pid] = paneID
                lock.unlock()
                client.send(.created(paneID: paneID, requestID: params.requestID))
            } catch {
                client.send(.error(error.localizedDescription, requestID: params.requestID))
            }

        case .attach(let paneID):
            let proc = withProcess(paneID: paneID)
            guard let proc else {
                client.send(.error("pane not found", requestID: nil))
                return
            }
            proc.attach(client: client)

        case .input(let paneID, let data):
            guard let proc = withProcess(paneID: paneID), let bytes = Data(base64Encoded: data) else { return }
            proc.write(bytes)

        case .resize(let paneID, let rows, let cols):
            withProcess(paneID: paneID)?.resize(rows: rows, cols: cols)

        case .list(let requestID):
            pruneMissingProcesses()
            lock.lock()
            let infos = processes.values.map(\.info)
            lock.unlock()
            client.send(.listed(infos, requestID: requestID))

        case .agentEvent(let event):
            guard let proc = process(stableID: event.stableID),
                  let status = proc.applyAgentEvent(event) else { return }
            broadcast(.agentStatus(status))

        case .close(let paneID):
            let proc = withProcess(paneID: paneID)
            if proc?.terminate() == false {
                removeProcess(paneID: paneID, pid: proc?.pid)
            }
            client.send(.ok)
        }
    }

    // MARK: - Child reaping

    func reapExited(pid: pid_t, exitCode: Int32) {
        let proc: PTYProcess?
        lock.lock()
        if let paneID = pidToPaneID.removeValue(forKey: pid) {
            proc = processes.removeValue(forKey: paneID)
        } else {
            proc = nil
        }
        lock.unlock()

        proc?.markExited(code: exitCode)
    }

    private func withProcess(paneID: String) -> PTYProcess? {
        lock.lock()
        let proc = processes[paneID]
        lock.unlock()
        return proc
    }

    private func process(stableID: String) -> PTYProcess? {
        lock.lock()
        let proc = processes.values.first { $0.stableID == stableID }
        lock.unlock()
        return proc
    }

    private func broadcast(_ response: DaemonResponse) {
        lock.lock()
        let snapshot = Array(clients.values)
        lock.unlock()
        for client in snapshot {
            client.send(response)
        }
    }

    private func pruneMissingProcesses() {
        lock.lock()
        let missing = processes.filter { !$0.value.exists }
        for (paneID, proc) in missing {
            processes.removeValue(forKey: paneID)
            pidToPaneID.removeValue(forKey: proc.pid)
        }
        lock.unlock()
    }

    private func removeProcess(paneID: String, pid: pid_t?) {
        lock.lock()
        processes.removeValue(forKey: paneID)
        if let pid {
            pidToPaneID.removeValue(forKey: pid)
        }
        lock.unlock()
    }
}
