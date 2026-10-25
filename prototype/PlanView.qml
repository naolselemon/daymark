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
    spacing: theme.space(24)
    PinnedActivities { workspace: root.workspace; visible: entries.length > 0 && !root.workspace.planPinsInHeader; Layout.fillWidth: true }
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
        columns: width >= root.theme.space(760) ? 2 : 1
        uniformCellWidths: true
        columnSpacing: root.theme.space(24); rowSpacing: root.theme.space(24)
        Repeater {
            model: ["Today", "Tomorrow", "Other days", "Inbox"]
            Rectangle {
                id: section
                required property string modelData
                property int sectionPage: 0
                readonly property var entries: root.visible ? root.workspace.agendaEntries(modelData) : []
                readonly property string day: modelData === "Today" ? root.store.today
                    : modelData === "Tomorrow" ? root.workspace.offsetDay(root.store.today, 1) : ""
                onEntriesChanged: sectionPage = Math.min(sectionPage, Math.max(0, Math.ceil(entries.length / 50) - 1))
                objectName: "planGroup-" + modelData
                visible: entries.length > 0
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                implicitHeight: sectionContent.implicitHeight + root.theme.space(40)
                color: root.theme.surface; radius: root.theme.radius
                border.color: Qt.rgba(root.theme.border.r, root.theme.border.g, root.theme.border.b, root.theme.border.a * 0.4)
                ColumnLayout {
                    id: sectionContent
                    anchors.fill: parent; anchors.margins: root.theme.space(20)
                    spacing: root.theme.space(12)
                    RowLayout {
                        Layout.fillWidth: true; spacing: root.theme.space(12)
                        SectionHeading { theme: root.theme; text: section.modelData; hint: section.modelData === "Inbox" ? "No date yet." : ""; Layout.fillWidth: true }
                        DText {
                            theme: root.theme; visible: section.day !== ""
                            text: section.day ? Qt.formatDate(new Date(section.day + "T12:00:00"), "d MMM") : ""
                            color: root.theme.secondary; font.pixelSize: root.theme.small
                        }
                    }
                    Repeater {
                        model: section.entries.slice(section.sectionPage * 50, (section.sectionPage + 1) * 50)
                        ActivityRow {
                            required property var modelData
                            theme: root.theme; activity: modelData; Layout.fillWidth: true; showNavigation: true
                            contextText: section.modelData === "Other days" ? Display.day(modelData.plannedFor, root.store.today) : ""
                            actionsEnabled: !root.workspace.actionPending
                            onDetailsRequested: id => root.workspace.selectActivity(id)
                            onCompleteRequested: id => root.workspace.completeActivity(id)
                        }
                    }
                    Item { Layout.fillHeight: true; Layout.preferredHeight: 0 }
                    RowLayout {
                        visible: section.entries.length > 50 || section.sectionPage > 0; Layout.fillWidth: true
                        DButton { theme: root.theme; text: "Previous"; iconName: "previous"; objectName: "planPrevious-" + section.modelData; enabled: section.sectionPage > 0; onClicked: section.sectionPage-- }
                        DText { theme: root.theme; text: "Page " + (section.sectionPage + 1); Layout.fillWidth: true }
                        DButton { theme: root.theme; text: "Next"; iconName: "next"; objectName: "planNext-" + section.modelData; enabled: (section.sectionPage + 1) * 50 < section.entries.length; onClicked: section.sectionPage++ }
                    }
                }
            }
        }
    }
}
