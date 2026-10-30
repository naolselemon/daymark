import QtQuick
import qs.Ui as Ui
import "../prototype" as Daymark

// The service owns this eager panel, not a per-monitor bar loader. Closing or
// resizing only changes presentation; controllers and drafts keep their identity.
Ui.Panel {
    id: root
    required property var service
    property var hostWidget: null
    readonly property var workspace: workspaceView
    moduleName: "naolselemon.daymark"
    manageIpc: false
    bar: hostWidget ? hostWidget.barHost : null

    function close() { return service.dismiss(); }
    function closeForPopoutSwitch() {
        popoutSwitchClosing = true;
        service.dismiss();
        Qt.callLater(() => { popoutSwitchClosing = false; });
    }

    Ui.KeyboardPanel {
        id: popup
        objectName: "daymarkNativePanel"
        bar: root.bar
        anchorItem: root.hostWidget ? root.hostWidget.anchorItem : null
        owner: root.hostWidget || root
        open: root.opened
        padding: 0
        contentWidth: fittedContentWidth(root.service.theme.space(workspaceView.expanded ? 960 : 480))
        contentHeight: cappedContentHeight(root.service.theme.space(workspaceView.expanded ? 800 : 760))
        focusTarget: workspaceView

        Daymark.Workspace {
            id: workspaceView
            anchors.fill: parent
            theme: root.service.theme
            store: root.service.records
            diaryAuth: root.service.diaryAuth
            updateTransport: root.service.updateTransport
            calendarTransport: root.service.calendarTransport
            idleMonitor: root.service.diaryIdle
            anchoredPanel: true
            onDismissRequested: root.service.dismiss()
            notificationTransport: root.service.notificationTransport
            presentationActive: root.opened
            profileLabel: qsTr("Local profile")
            onPresentRequested: root.service.open()
            onCloseRequested: root.service.close()
        }
    }
}
