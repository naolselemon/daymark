import QtQuick
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
    readonly property bool opened: panelHost.opened
    property var barWidgets: []
    property WorkspacePanel panel: WorkspacePanel { id: panelHost; service: root }
    readonly property var workspace: panelHost.workspace
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
    property Daymark.QuickshellNotificationTransport notificationTransport: Daymark.QuickshellNotificationTransport {}
    property Daymark.PersistentStore records: Daymark.PersistentStore { transport: root.transport }
    property Daymark.SystemPasswordAuth diaryAuth: Daymark.SystemPasswordAuth {}
    property IpcHandler updateReadiness: IpcHandler {
        target: "naolselemon.daymark"
        function updateReadiness(): string {
            return JSON.stringify({
                protocol: 1,
                ready: root.workspace.runtimeReady,
                barReady: root.readyBarWidgets > 0,
                source: decodeURIComponent(Qt.resolvedUrl("..").toString().slice(7)).replace(/\/$/, "")
            });
        }
    }
    function registerBarWidget(widget) {
        if (barWidgets.indexOf(widget) >= 0) return;
        barWidgets = barWidgets.concat([widget]);
        readyBarWidgets = barWidgets.length;
        if (!panelHost.hostWidget) panelHost.hostWidget = widget;
    }
    function unregisterBarWidget(widget) {
        barWidgets = barWidgets.filter(candidate => candidate !== widget);
        readyBarWidgets = barWidgets.length;
        if (panelHost.hostWidget === widget) {
            // A bar/output disappearing must not destroy the service's drafts.
            dismiss();
            panelHost.hostWidget = barWidgets.length ? barWidgets[0] : null;
        }
    }
    function open(widget) {
        if (widget && barWidgets.indexOf(widget) >= 0) panelHost.hostWidget = widget;
        if (opened) return;
        panelHost.controller.show();
        records.reload();
    }
    function dismiss() {
        if (!workspace.prepareDismiss()) return false;
        panelHost.controller.hide();
        return true;
    }
    function close() {
        if (!workspace.requestClose()) return false;
        return dismiss();
    }
    function toggle(widget) {
        if (opened) dismiss();
        else open(widget);
    }
}
