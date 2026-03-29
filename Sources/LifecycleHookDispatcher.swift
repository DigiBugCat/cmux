import Foundation
import os.log

/// Dispatches lifecycle hooks stored in the tmux-compat store.
///
/// Hooks are persisted by the CLI via `cmux set-hook <event> <command>` in
/// `~/.cmuxterm/tmux-compat-store.json`.  The app loads that file and fires
/// matching shell commands asynchronously at the appropriate lifecycle points.
///
/// Supported events (fired by the app):
///   - `after-restore`      — after session restore completes on launch
///   - `session-created`    — after applicationDidFinishLaunching
///   - `workspace-created`  — after a new workspace is added
///   - `workspace-closed`   — after a workspace is closed
///   - `before-shutdown`    — before the app terminates
enum LifecycleHookDispatcher {

    // MARK: - Store format (mirrors CLI TmuxCompatStore, decode-only)

    private struct TmuxCompatStore: Decodable {
        var hooks: [String: String] = [:]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hooks = try container.decodeIfPresent([String: String].self, forKey: .hooks) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case hooks
        }
    }

    // MARK: - Public API

    /// Fire the hook for `event` if one is registered.  Runs the command
    /// asynchronously on a background queue so it never blocks the main thread.
    /// Environment variables `CMUX_HOOK_EVENT` and optionally
    /// `CMUX_HOOK_WORKSPACE_ID` are passed to the child process.
    static func dispatch(
        _ event: String,
        workspaceId: String? = nil,
        environment: [String: String] = [:]
    ) {
        dispatchQueue.async {
            guard let command = loadHook(for: event) else { return }
            executeShellCommand(command, event: event, workspaceId: workspaceId, environment: environment)
        }
    }

    /// Fire the hook for `event` synchronously with a bounded wait.
    /// Use this for shutdown hooks where the process may exit immediately after.
    static func dispatchSync(
        _ event: String,
        workspaceId: String? = nil,
        environment: [String: String] = [:],
        timeout: DispatchTime = .now() + 5
    ) {
        guard let command = loadHook(for: event) else { return }
        let semaphore = DispatchSemaphore(value: 0)
        dispatchQueue.async {
            executeShellCommand(
                command,
                event: event,
                workspaceId: workspaceId,
                environment: environment,
                waitForExit: true
            )
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: timeout)
    }

    // MARK: - Internals

    private static let log = OSLog(
        subsystem: "com.cmuxterm.app",
        category: "LifecycleHooks"
    )

    private static let dispatchQueue = DispatchQueue(
        label: "com.cmuxterm.app.lifecycleHooks",
        qos: .utility
    )

    private static func storeURL() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSString(string: "~").expandingTildeInPath
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".cmuxterm")
            .appendingPathComponent("tmux-compat-store.json")
    }

    private static func loadHook(for event: String) -> String? {
        let url = storeURL()
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(TmuxCompatStore.self, from: data) else {
            return nil
        }
        let command = store.hooks[event]
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return command
    }

    private static func executeShellCommand(
        _ command: String,
        event: String,
        workspaceId: String?,
        environment: [String: String],
        waitForExit: Bool = false
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        // Apply caller environment first, then set reserved keys so they
        // cannot be overwritten.
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        env["CMUX_HOOK_EVENT"] = event
        if let workspaceId {
            env["CMUX_HOOK_WORKSPACE_ID"] = workspaceId
        } else {
            env.removeValue(forKey: "CMUX_HOOK_WORKSPACE_ID")
        }
        process.environment = env

        // Detach stdin so the child doesn't block on terminal input.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            if waitForExit {
                process.waitUntilExit()
            }
        } catch {
            os_log(
                .error,
                log: self.log,
                "Failed to run hook '%{public}@': %{public}@",
                event,
                error.localizedDescription
            )
        }
    }
}
