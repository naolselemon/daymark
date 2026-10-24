import QtQuick
import QtQuick.Window
import QtQuick.Layouts

Window {
    id: root
    required property var themeData
    required property var transport
    // Native PAM is statically linked into Quickshell, not the Qt preview host.
    // Without an actual authenticator, diary and protected archive actions stay locked.
    property var diaryAuth: null
    property string profileLabel: "Isolated profile"
    property bool demoMode: false
    property bool temporaryProfile: false
    property bool scenarioApplied: false
    property string scenario: "timer"
    property string capturePath: ""
    property alias workspace: workspaceView
    property alias store: records
    property alias statusWindow: barWindow
    property bool showStatusWindow: capturePath === ""
    width: themePalette.space(560)
    height: themePalette.space(740)
    minimumWidth: themePalette.space(440)
    minimumHeight: themePalette.space(480)
    visible: true
    title: "Daymark · " + (demoMode ? "synthetic demo" : profileLabel)
    color: themePalette.background

    Theme { id: themePalette; source: root.themeData }
    Connections {
        target: root.transport
        function onThemeChanged(snapshot) {
            // Replace only the token value: window, store and editor identities
            // (including unsaved drafts) remain untouched.
            root.themeData = snapshot;
        }
    }
    PersistentStore { id: records; transport: root.transport }
    Workspace {
        id: workspaceView
        anchors.fill: parent
        theme: themePalette
        store: records
        diaryAuth: root.diaryAuth
        profileLabel: root.profileLabel
        demoMode: root.demoMode
        temporaryProfile: root.temporaryProfile
        onCloseRequested: root.close()
    }
    // Development launcher: reopening uses the same journal and retained drafts.
    Window {
        id: barWindow
        objectName: "statusWindow"
        width: themePalette.space(320)
        height: statusLayout.implicitHeight + themePalette.space(16)
        minimumWidth: themePalette.space(240)
        visible: root.showStatusWindow
        title: "Daymark launcher"
        color: themePalette.background
        ColumnLayout {
            id: statusLayout
            anchors.fill: parent
            anchors.margins: themePalette.space(8)
            spacing: themePalette.gap
            DaymarkLauncher {
                objectName: "previewDaymarkLauncher"
                Layout.fillWidth: true
                theme: themePalette
                store: records
                onOpenRequested: root.openWorkspace()
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                DButton {
                    objectName: "quitPreviewButton"
                    theme: themePalette
                    text: "Quit preview"
                    onClicked: root.quitPreview()
                }
            }
        }
        onClosing: close => {
            close.accepted = false;
            root.quitPreview();
        }
    }
    function openWorkspace() {
        visible = true;
        raise();
        requestActivate();
        records.reload();
    }
    function quitPreview() {
        if (!workspaceView.requestClose()) {
            openWorkspace();
            return;
        }
        Qt.quit();
    }
    function applyScenario() {
        if (scenarioApplied || !records.loaded) return;
        scenarioApplied = true;
        workspaceView.page = scenario === "timer" ? "Timer" : "Today";
        if (scenario === "plan") workspaceView.page = "Plan";
        else if (scenario === "history" || scenario === "empty-history") workspaceView.page = "History";
        else if (scenario === "detail" && records.activities.length) {
            const coding = records.activities.find(a => a.category === "Coding");
            workspaceView.selectedId = coding ? coding.id : records.activities[0].id;
        } else if (scenario === "long" && records.activities.length) {
            workspaceView.selectedId = records.activities.reduce((a, b) => a.title.length > b.title.length ? a : b).id;
        } else if (scenario === "composer") workspaceView.openComposer("log", "");
        else if (scenario === "keyboard") workspaceView.focusAdd();
        console.info("Daymark native preview ready · isolated SQLite profile · " + scenario);
    }
    Connections { target: records; function onLoadedChanged() { Qt.callLater(root.applyScenario); } }
    onClosing: close => {
        close.accepted = false;
        if (workspaceView.requestClose()) root.visible = false;
    }
    Timer {
        interval: 8000
        running: root.capturePath !== ""
        onTriggered: {
            console.error("No native frame captured. The display may be asleep or the window unexposed; no image was produced.");
            Qt.exit(1);
        }
    }

    // Capture only this rendered native item tree, never the desktop or other
    // applications. This optional review mode closes after writing one image.
    Timer {
        interval: 1000
        running: root.capturePath !== "" && root.scenarioApplied && !records.busy && !records.historyLoading
        onTriggered: root.contentItem.grabToImage(result => {
            if (!result.saveToFile(root.capturePath)) {
                console.error("Could not write native preview capture.");
                Qt.exit(1);
            } else {
                console.info("Native QML capture written: " + root.capturePath);
                Qt.quit();
            }
        })
    }
}
