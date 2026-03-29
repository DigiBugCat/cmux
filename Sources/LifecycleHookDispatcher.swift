import Foundation

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
        guard let command = loadHook(for: event) else { return }
        dispatchQueue.async {
            executeShellCommand(command, event: event, workspaceId: workspaceId, environment: environment)
        }
    }

    // MARK: - Internals

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
        environment: [String: String]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        var env = ProcessInfo.processInfo.environment
        env["CMUX_HOOK_EVENT"] = event
        if let workspaceId {
            env["CMUX_HOOK_WORKSPACE_ID"] = workspaceId
        }
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        // Detach stdin so the child doesn't block on terminal input.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            // Fire-and-forget — don't waitUntilExit on the dispatch queue.
        } catch {
            #if DEBUG
            NSLog("[LifecycleHookDispatcher] Failed to run hook '\(event)': \(error.localizedDescription)")
            #endif
        }
    }
}
