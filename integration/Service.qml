import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../prototype" as Daymark

// One instance per enabled plugin, supplied by the installed host service registry.
// Keep the original storage identity: renaming the app must not strand records.
QtObject {
    id: root
    property var shell: null
    property var manifest: null
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || ""
    property string profilePath: (dataHome.startsWith("/") ? dataHome : Quickshell.env("HOME") + "/.local/share") + "/daylog"
    property string pythonExecutable: "/usr/bin/python"
    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("../backend/helper.py").toString().slice(7))
    property int readyBarWidgets: 0
    readonly property bool opened: workspaceWindow.visible
    property ShellTheme theme: ShellTheme {}
    property Daymark.QuickshellTransport transport: Daymark.QuickshellTransport {
        pythonExecutable: root.pythonExecutable
        helperPath: root.helperPath
        profilePath: root.profilePath
    }
    property Daymark.QuickshellTransport updateTransport: Daymark.QuickshellTransport {
        pythonExecutable: root.pythonExecutable
        helperPath: decodeURIComponent(Qt.resolvedUrl("../backend/updater.py").toString().slice(7))
        profilePath: root.profilePath
        helperName: "update"
        timeoutMs: 300000
        watchProfile: false
    }
    property Daymark.QuickshellTransport calendarTransport: Daymark.QuickshellTransport {
        pythonExecutable: root.pythonExecutable
        helperPath: decodeURIComponent(Qt.resolvedUrl("../backend/calendar_feed.py").toString().slice(7))
        profilePath: root.profilePath
        helperName: "calendar"
        timeoutMs: 20000
        watchProfile: false
    }
    property IdleMonitor diaryIdle: IdleMonitor {
        enabled: false
        respectInhibitors: false
    }
    property Daymark.PersistentStore records: Daymark.PersistentStore { transport: root.transport }
    property Daymark.SystemPasswordAuth diaryAuth: Daymark.SystemPasswordAuth {}
    property IpcHandler updateReadiness: IpcHandler {
        target: "naolselemon.daymark"
        function updateReadiness(): string {
            return JSON.stringify({
                protocol: 1,
                ready: workspace.runtimeReady,
                barReady: root.readyBarWidgets > 0,
                source: decodeURIComponent(Qt.resolvedUrl("..").toString().slice(7)).replace(/\/$/, "")
            });
        }
    }
    property Window workspaceWindow: Window {
        width: root.theme.space(1440)
        height: root.theme.space(900)
        minimumWidth: root.theme.space(440)
        minimumHeight: root.theme.space(480)
        visible: false
        title: "Daymark"
        color: root.theme.background
        Daymark.Workspace {
            id: workspace
            anchors.fill: parent
            theme: root.theme
            store: root.records
            diaryAuth: root.diaryAuth
            updateTransport: root.updateTransport
            calendarTransport: root.calendarTransport
            idleMonitor: root.diaryIdle
            profileLabel: "Local profile"
            onCloseRequested: root.close()
        }
        onClosing: event => {
            event.accepted = false;
            root.close();
        }
    }
    function open() {
        workspaceWindow.visible = true;
        workspaceWindow.raise();
        workspaceWindow.requestActivate();
        records.reload();
    }
    function close() {
        if (!workspace.requestClose()) return false;
        workspaceWindow.visible = false;
        return true;
    }
    function toggle() {
        if (opened) close();
        else open();
    }
}
