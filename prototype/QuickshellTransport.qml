import QtQuick
import Quickshell.Io

// Shared shell-service transport. Each request is a short-lived helper process.
QtObject {
    id: root
    required property string pythonExecutable
    required property string helperPath
    required property string profilePath
    property bool readOnly: false
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

    function complete(request, response, error) {
        if (activeRequest !== request)
            return
        deadline.stop()
        activeRequest = null
        request.destroy()
        watchReady = true
        finished(response, error)
    }

    property Timer deadline: Timer {
        interval: 15000
        onTriggered: {
            const request = root.activeRequest
            if (request === null)
                return
            request.failure = request.didStart
                ? "The storage helper timed out; the save outcome is unknown. Retry the same request."
                : "The storage helper could not start."
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
                write(payload + "\n")
                payload = ""
                stdinEnabled = false
            }
            onRunningChanged: {
                if (!running && !didStart) {
                    Qt.callLater(function() {
                        if (root.activeRequest === request && !request.running && !request.didStart)
                            root.complete(request, "", "The storage helper could not start.")
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
                        root.complete(request, "", "The storage helper exited unsuccessfully; the save outcome may be unknown.")
                        return
                    }
                    const response = responseCollector.text.trim()
                    try {
                        const parsed = JSON.parse(response)
                        if (response.indexOf("\n") !== -1 || parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
                            throw new Error("Invalid response")
                    } catch (_) {
                        root.complete(request, "", "The storage helper returned a missing or malformed response.")
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
            finished("", "The storage request was interrupted by transport shutdown; its outcome may be unknown.")
        }
    }
}
