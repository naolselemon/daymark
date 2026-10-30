pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io

// Argv-based children live only for their request or notification; no extra shell.
QtObject {
    id: root
    readonly property bool enabled: true
    readonly property string unavailableReason: ""
    property var requests: ({})
    property bool shuttingDown: false
    signal finished(string token, string output, string failure)

    function execute(token: string, commandArgs: var, timeoutMs: int): bool {
        if (shuttingDown || requests[token] || !Array.isArray(commandArgs) || commandArgs.length === 0)
            return false
        const request = requestFactory.createObject(root, {
            token: token, command: commandArgs, timeoutMs: timeoutMs
        }) as NotificationRequest
        if (!request)
            return false
        requests[token] = request
        request.running = true
        if (timeoutMs > 0)
            request.deadline.start()
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
        stdout: StdioCollector { id: result }
        stderr: StdioCollector {}
        onStarted: didStart = true
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
                root.complete(request, result.text,
                    request.failure || (exitCode !== 0 || exitStatus !== 0
                        ? "The desktop notification command failed." : ""))
            })
        }
    }
    property Component requestFactory: Component { NotificationRequest {} }
    Component.onDestruction: {
        shuttingDown = true
        for (const token in requests)
            requests[token].signal(9)
    }
}
