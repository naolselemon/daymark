import QtQuick
import QtQuick.Window
import Quickshell
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
    readonly property bool opened: workspaceWindow.visible
    property ShellTheme theme: ShellTheme {}
    property Daymark.QuickshellTransport transport: Daymark.QuickshellTransport {
        pythonExecutable: root.pythonExecutable
        helperPath: root.helperPath
        profilePath: root.profilePath
    }
    property Daymark.PersistentStore records: Daymark.PersistentStore { transport: root.transport }
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
