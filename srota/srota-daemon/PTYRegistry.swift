import Foundation

final class PTYRegistry {
    private var processes: [String: PTYProcess] = [:]
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
        for proc in processes.values { proc.removeSubscriber(client) }
        lock.unlock()
    }

    // MARK: - Command dispatch

    func handle(_ req: DaemonRequest, from client: ClientSession) {
        switch req {
        case .create(let params):
            let paneID = UUID().uuidString
            do {
                let proc = try PTYProcess(
                    paneID: paneID,
                    stableID: params.stableID,
                    cmd: params.cmd,
                    cwd: params.cwd,
                    env: params.env
                )
                lock.lock()
                processes[paneID] = proc
                lock.unlock()
                client.send(.created(paneID: paneID))
            } catch {
                client.send(.error(error.localizedDescription))
            }

        case .attach(let paneID):
            lock.lock()
            let proc = processes[paneID]
            lock.unlock()
            guard let proc else { client.send(.error("pane not found")); return }
            proc.attach(client: client)

        case .input(let paneID, let data):
            lock.lock()
            let proc = processes[paneID]
            lock.unlock()
            guard let proc, let bytes = Data(base64Encoded: data) else { return }
            proc.write(bytes)

        case .resize(let paneID, let rows, let cols):
            lock.lock()
            let proc = processes[paneID]
            lock.unlock()
            proc?.resize(rows: rows, cols: cols)

        case .list:
            lock.lock()
            let infos = processes.values.map { $0.info }
            lock.unlock()
            client.send(.listed(infos))

        case .close(let paneID):
            lock.lock()
            let proc = processes.removeValue(forKey: paneID)
            lock.unlock()
            proc?.terminate()
            client.send(.ok)
        }
    }

    // MARK: - Child reaping

    func reapExited(pid: pid_t, exitCode: Int32) {
        lock.lock()
        for proc in processes.values where proc.pid == pid {
            proc.markExited(code: exitCode)
        }
        lock.unlock()
    }
}
