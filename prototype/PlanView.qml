pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    required property var workspace
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    spacing: theme.space(28)
    PinnedActivities { workspace: root.workspace; Layout.fillWidth: true }
    Repeater {
        model: ["Today", "Tomorrow", "Other days", "Inbox"]
        ColumnLayout {
            id: section
            required property string modelData
            property int sectionPage: 0
            readonly property var entries: root.visible ? root.workspace.agendaEntries(modelData) : []
            onEntriesChanged: sectionPage = Math.min(sectionPage, Math.max(0, Math.ceil(entries.length / 50) - 1))
            Layout.fillWidth: true; spacing: root.theme.space(10)
            SectionHeading { theme: root.theme; text: section.modelData; hint: section.modelData === "Inbox" ? "Someday, when there's room." : ""; Layout.fillWidth: true }
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
            DText { theme: root.theme; text: section.modelData === "Inbox" ? "No unscheduled activities." : "Nothing planned."; color: root.theme.secondary; visible: section.entries.length === 0; Layout.fillWidth: true }
            RowLayout {
                visible: section.entries.length > 50 || section.sectionPage > 0; Layout.fillWidth: true
                DButton { theme: root.theme; text: "Previous"; enabled: section.sectionPage > 0; onClicked: section.sectionPage-- }
                DText { theme: root.theme; text: "Page " + (section.sectionPage + 1); Layout.fillWidth: true }
                DButton { theme: root.theme; text: "Next"; enabled: (section.sectionPage + 1) * 50 < section.entries.length; onClicked: section.sectionPage++ }
            }
        }
    }
}
