pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io

// Private request input stays on stdin; children live only for their bounded request.
QtObject {
    id: root
    readonly property bool enabled: true
    readonly property string unavailableReason: ""
    property var requests: ({})
    property bool shuttingDown: false
    signal finished(string token, string output, string failure)

    function execute(token: string, commandArgs: var, timeoutMs: real, inputText: string): bool {
        if (shuttingDown || requests[token] || !Array.isArray(commandArgs) || commandArgs.length === 0
                || !Number.isFinite(timeoutMs) || !Number.isInteger(timeoutMs)
                || timeoutMs <= 0 || timeoutMs > 65000 || typeof inputText !== "string")
            return false
        const request = requestFactory.createObject(root, {
            token: token, command: commandArgs, timeoutMs: timeoutMs, payload: inputText
        }) as NotificationRequest
        if (!request)
            return false
        requests[token] = request
        request.deadline.start()
        request.running = true
        return true
    }

    function complete(request, output, failure) {
        if (requests[request.token] !== request)
            return
        delete requests[request.token]
        request.deadline.stop()
        const token = request.token
        request.destroy()
        if (!shuttingDown)
            finished(token, output, failure)
    }

    component NotificationRequest: Process {
        id: request
        property string token
        property int timeoutMs
        property string payload
        property bool didStart: false
        property string failure: ""
        property Timer deadline: Timer {
            interval: request.timeoutMs
            onTriggered: {
                request.failure = "The desktop notification request timed out."
                if (request.running)
                    request.signal(9)
                else
                    root.complete(request, "", request.failure)
            }
        }
        stdinEnabled: true
        stdout: StdioCollector { id: result }
        stderr: StdioCollector {}
        onStarted: {
            didStart = true
            if (root.shuttingDown || failure !== "") {
                payload = ""
                stdinEnabled = false
                signal(9)
                return
            }
            write(payload)
            payload = ""
            stdinEnabled = false
        }
        onRunningChanged: {
            if (!running && !didStart) {
                Qt.callLater(function() {
                    if (root.requests[request.token] === request && !request.running && !request.didStart)
                        root.complete(request, "", "The desktop notification command could not start.")
                })
            }
        }
        onExited: function(exitCode, exitStatus) {
            Qt.callLater(function() {
                const failure = request.failure || (exitCode !== 0 || exitStatus !== 0
                    ? "The desktop notification command failed." : "")
                root.complete(request, failure ? "" : result.text, failure)
            })
        }
    }

    property Component requestFactory: Component {
        NotificationRequest {}
    }
    Component.onDestruction: {
        shuttingDown = true
        for (const token in requests) {
            requests[token].deadline.stop()
            requests[token].payload = ""
            requests[token].signal(9)
        }
    }
}
