import QtQuick
import Quickshell.Io

// Shared shell-service transport. Each request is a short-lived helper process.
QtObject {
    id: root
    required property string pythonExecutable
    required property string helperPath
    required property string profilePath
    property bool readOnly: false
    property int timeoutMs: 15000
    property bool watchProfile: true
    property string helperName: "storage"
    property var activeRequest: null
    property bool shuttingDown: false
    signal finished(string response, string transportError)
    signal dataChanged()
    property bool watchReady: false

    property FileView databaseWatch: FileView {
        path: root.watchReady ? root.profilePath + "/daylog.sqlite3" : ""
        preload: false
        blockAllReads: true
        watchChanges: true
        printErrors: false
        onFileChanged: root.dataChanged()
    }
    property FileView directoryWatch: FileView {
        path: root.watchReady ? root.profilePath : ""
        preload: false
        blockAllReads: true
        watchChanges: true
        printErrors: false
        onFileChanged: root.dataChanged()
    }

    function send(jsonLine: string): bool {
        if (activeRequest !== null || shuttingDown)
            return false
        const args = [pythonExecutable, helperPath, "--profile", profilePath]
        if (readOnly)
            args.push("--read-only")
        const request = requestFactory.createObject(root, { command: args, payload: jsonLine }) as Process
        if (request === null)
            return false
        activeRequest = request
        request.stdinEnabled = true
        request.running = true
        deadline.start()
        return true
    }

    function cancel(): void {
        const request = activeRequest
        if (request === null)
            return
        request.failure = "The " + helperName + " request was cancelled; checking saved state."
        if (request.running)
            request.signal(9)
    }

    function complete(request, response, error) {
        if (activeRequest !== request)
            return
        deadline.stop()
        activeRequest = null
        request.destroy()
        watchReady = watchProfile
        finished(response, error)
    }

    property Timer deadline: Timer {
        interval: root.timeoutMs
        onTriggered: {
            const request = root.activeRequest
            if (request === null)
                return
            request.failure = request.didStart
                ? "The " + root.helperName + " helper timed out; the operation outcome is unknown."
                : "The " + root.helperName + " helper could not start."
            if (request.running)
                request.signal(9)
            else
                root.complete(request, "", request.failure)
        }
    }

    property Component requestFactory: Component {
        Process {
            id: request
            property string payload
            property string failure: ""
            property bool didStart: false
            stdinEnabled: true
            stdout: StdioCollector { id: responseCollector }
            // Never forward helper diagnostics or request/response bodies to logs.
            stderr: StdioCollector {}
            onStarted: {
                didStart = true
                if (failure !== "") {
                    payload = ""
                    signal(9)
                    return
                }
                write(payload + "\n")
                payload = ""
                stdinEnabled = false
            }
            onRunningChanged: {
                if (!running && !didStart) {
                    Qt.callLater(function() {
                        if (root.activeRequest === request && !request.running && !request.didStart)
                            root.complete(request, "", "The " + root.helperName + " helper could not start.")
                    })
                }
            }
            onExited: function(exitCode, exitStatus) {
                // Let stdout's end-of-stream collector finish before inspecting it.
                Qt.callLater(function() {
                    if (root.activeRequest !== request)
                        return
                    if (request.failure !== "") {
                        root.complete(request, "", request.failure)
                        return
                    }
                    if (exitCode !== 0 || exitStatus !== 0) {
                        root.complete(request, "", "The " + root.helperName + " helper exited unsuccessfully; the operation outcome may be unknown.")
                        return
                    }
                    const response = responseCollector.text.trim()
                    try {
                        const parsed = JSON.parse(response)
                        if (response.indexOf("\n") !== -1 || parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
                            throw new Error("Invalid response")
                    } catch (_) {
                        root.complete(request, "", "The " + root.helperName + " helper returned a missing or malformed response.")
                        return
                    }
                    root.complete(request, response, "")
                })
            }
        }
    }

    Component.onDestruction: {
        shuttingDown = true
        deadline.stop()
        if (activeRequest !== null) {
            activeRequest.signal(9)
            finished("", "The " + helperName + " request was interrupted; its outcome may be unknown.")
        }
    }
}
