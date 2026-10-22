pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    required property var workspace
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    readonly property bool hasPlans: store.activities.some(activity => activity.status === "open")
    spacing: theme.space(36)
    PinnedActivities { workspace: root.workspace; Layout.fillWidth: true }
    Item {
        visible: !root.hasPlans
        Layout.fillWidth: true; implicitHeight: root.theme.space(220)
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width, root.theme.space(460))
            spacing: root.theme.space(14)
            DText { theme: root.theme; text: "Room for a new plan."; font.pixelSize: root.theme.title; font.italic: true; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
            DText { theme: root.theme; text: "Use Add plan to collect what you'd like to do. You can add several without closing the form."; color: root.theme.secondary; font.italic: true; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
        }
    }
    GridLayout {
        Layout.fillWidth: true
        columns: width >= root.theme.space(780) ? 2 : 1
        uniformCellWidths: true
        columnSpacing: root.theme.space(32); rowSpacing: root.theme.space(36)
        Repeater {
            model: ["Today", "Tomorrow", "Other days", "Inbox"]
            ColumnLayout {
                id: section
                required property string modelData
                property int sectionPage: 0
                readonly property var entries: root.visible ? root.workspace.agendaEntries(modelData) : []
                onEntriesChanged: sectionPage = Math.min(sectionPage, Math.max(0, Math.ceil(entries.length / 50) - 1))
                visible: entries.length > 0
                Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.alignment: Qt.AlignTop
                spacing: root.theme.space(14)
                SectionHeading { theme: root.theme; text: section.modelData; hint: section.modelData === "Inbox" ? "No date yet." : ""; Layout.fillWidth: true }
                Repeater {
                    model: section.entries.slice(section.sectionPage * 50, (section.sectionPage + 1) * 50)
                    ActivityRow {
                        required property var modelData
                        theme: root.theme; activity: modelData; Layout.fillWidth: true
                        contextText: section.modelData === "Other days" ? Display.day(modelData.plannedFor, root.store.today) : ""
                        actionsEnabled: !root.workspace.actionPending
                        onDetailsRequested: id => root.workspace.selectActivity(id)
                        onCompleteRequested: id => root.workspace.completeActivity(id)
                    }
                }
                RowLayout {
                    visible: section.entries.length > 50 || section.sectionPage > 0; Layout.fillWidth: true
                    DButton { theme: root.theme; text: "Previous"; enabled: section.sectionPage > 0; onClicked: section.sectionPage-- }
                    DText { theme: root.theme; text: "Page " + (section.sectionPage + 1); Layout.fillWidth: true }
                    DButton { theme: root.theme; text: "Next"; enabled: (section.sectionPage + 1) * 50 < section.entries.length; onClicked: section.sectionPage++ }
                }
            }
        }
    }
}
