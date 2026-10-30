pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Popup {
    id: root
    objectName: "countdownTargetPicker"
    required property var theme
    required property var store
    property string activityId: ""
    property string taskId: ""
    property string expandedId: ""
    readonly property var matches: {
        const query = search.text.trim().toLowerCase();
        return store.activities.filter(activity => activity.status !== "done"
            && (!query || activity.title.toLowerCase().indexOf(query) >= 0
                || (activity.tasks || []).some(task => task.title.toLowerCase().indexOf(query) >= 0)));
    }
    readonly property var selectedActivity: store.activity(activityId)
    readonly property bool validTarget: !activityId || (!!selectedActivity && selectedActivity.status !== "done"
        && (!taskId || (selectedActivity.tasks || []).some(task => task.id === taskId)))
    signal chosen(string activityId, string taskId)
    modal: true
    focus: true
    closePolicy: Popup.NoAutoClose
    width: Math.min(parent ? parent.width : theme.space(440), theme.space(720))
    height: parent ? parent.height : Math.min(implicitHeight, theme.space(680))
    implicitHeight: body.implicitHeight + padding * 2
    x: parent ? (parent.width - width) / 2 : 0
    y: 0
    padding: theme.space(12)
    background: Rectangle { color: root.theme.background; border.color: root.theme.border; radius: root.theme.radius }

    function begin(activity, task) {
        activityId = activity || "";
        taskId = task || "";
        expandedId = activityId;
        search.text = "";
        open();
        search.forceActiveFocus();
    }
    function requestDismiss() { close(); return true; }
    function acceptTarget() {
        if (!validTarget) return;
        chosen(activityId, taskId);
        close();
    }
    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(8)
        Keys.onEscapePressed: event => { root.requestDismiss(); event.accepted = true; }
        RowLayout {
            Layout.fillWidth: true
            DButton { theme: root.theme; text: qsTr("Back"); iconName: "back"; quiet: true; onClicked: root.requestDismiss() }
            DText { theme: root.theme; text: qsTr("Focus on"); font.pixelSize: root.theme.heading; font.bold: true; Layout.fillWidth: true }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        DField {
            id: search
            objectName: "countdownTargetSearch"
            theme: root.theme
            placeholderText: qsTr("Find an activity or task…")
            Accessible.name: qsTr("Find an activity or task")
            Layout.fillWidth: true
        }
        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: Math.min(items.implicitHeight, root.theme.space(360))
            Layout.minimumHeight: root.theme.space(60)
            contentWidth: availableWidth
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: items
                width: scroll.availableWidth
                spacing: root.theme.space(4)
                Repeater {
                    model: root.matches
                    delegate: ColumnLayout {
                        id: activityRow
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: root.theme.space(4)
                        DButton {
                            theme: root.theme
                            text: activityRow.modelData.title
                            iconName: root.expandedId === activityRow.modelData.id ? "collapse" : "expand"
                            iconOnly: false
                            quiet: true
                            Layout.fillWidth: true
                            onClicked: root.expandedId = root.expandedId === activityRow.modelData.id ? "" : activityRow.modelData.id
                        }
                        ColumnLayout {
                            visible: root.expandedId === activityRow.modelData.id
                            Layout.fillWidth: true
                            Layout.leftMargin: root.theme.space(16)
                            spacing: root.theme.space(4)
                            DButton {
                                theme: root.theme
                                text: qsTr("Whole activity")
                                quiet: true
                                selected: root.activityId === activityRow.modelData.id && !root.taskId
                                Layout.fillWidth: true
                                onClicked: { root.activityId = activityRow.modelData.id; root.taskId = ""; }
                            }
                            Repeater {
                                model: activityRow.modelData.tasks || []
                                delegate: DButton {
                                    required property var modelData
                                    theme: root.theme
                                    text: modelData.title
                                    quiet: true
                                    selected: root.activityId === activityRow.modelData.id && root.taskId === modelData.id
                                    Layout.fillWidth: true
                                    onClicked: { root.activityId = activityRow.modelData.id; root.taskId = modelData.id; }
                                }
                            }
                        }
                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                    }
                }
                DText {
                    theme: root.theme
                    text: qsTr("No matching activities.")
                    visible: !root.matches.length
                    Layout.fillWidth: true
                    color: root.theme.secondary
                }
            }
        }
        DText {
            theme: root.theme
            text: qsTr("This target is no longer available. Choose an existing activity or task.")
            visible: !root.validTarget
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: root.theme.urgent
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: root.theme.space(12)
            DButton {
                objectName: "countdownNoActivity"
                theme: root.theme
                text: qsTr("No activity")
                selected: !root.activityId
                onClicked: { root.activityId = ""; root.taskId = ""; }
            }
            Item { Layout.fillWidth: true }
            DButton {
                objectName: "countdownUseTarget"
                theme: root.theme
                text: qsTr("Use target")
                iconName: "link"
                iconOnly: false
                primary: true
                enabled: root.validTarget
                onClicked: root.acceptTarget()
            }
        }
    }
}
