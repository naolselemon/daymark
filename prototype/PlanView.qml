pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    required property var workspace
    property var calendarController: null
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    readonly property bool hasPlans: store.activities.some(activity => activity.status === "open")
    property bool inboxExpanded: false
    readonly property bool wideAgenda: width >= theme.space(640)
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
    ColumnLayout {
        objectName: "planJournal"
        Layout.fillWidth: true; Layout.minimumWidth: 0
        spacing: root.theme.space(28)
        Repeater {
            model: ["Earlier", "Today", "Tomorrow", "Later", "Inbox"]
            ColumnLayout {
                id: section
                required property string modelData
                property int sectionPage: 0
                readonly property bool inbox: modelData === "Inbox"
                readonly property bool otherDays: modelData === "Earlier" || modelData === "Later"
                readonly property var entries: {
                    if (!root.visible) return [];
                    const rows = root.workspace.agendaEntries(otherDays ? "Other days" : modelData);
                    if (!otherDays) return rows;
                    return rows.filter(activity => modelData === "Earlier"
                        ? activity.plannedFor < root.store.today
                        : activity.plannedFor > root.workspace.offsetDay(root.store.today, 1))
                        .sort((a, b) => a.plannedFor.localeCompare(b.plannedFor));
                }
                onEntriesChanged: sectionPage = Math.min(sectionPage, Math.max(0, Math.ceil(entries.length / 50) - 1))
                objectName: "planGroup-" + modelData
                visible: entries.length > 0
                Layout.fillWidth: true; Layout.minimumWidth: 0
                spacing: root.theme.space(12)
                Rectangle {
                    visible: section.inbox
                    Layout.fillWidth: true; implicitHeight: 1
                    color: root.theme.border; opacity: 0.4
                }
                RowLayout {
                    visible: section.inbox
                    Layout.fillWidth: true; spacing: root.theme.space(12)
                    DText {
                        theme: root.theme; text: "Inbox"; font.italic: true
                        Layout.preferredWidth: root.wideAgenda ? root.theme.space(156) : implicitWidth
                    }
                    DText {
                        theme: root.theme; objectName: "planInboxCount"
                        text: section.entries.length + (section.entries.length === 1 ? " activity without a date" : " activities without a date")
                        font.pixelSize: root.theme.small; color: root.theme.secondary
                        Layout.fillWidth: true; Layout.minimumWidth: 0
                    }
                    DButton {
                        theme: root.theme; objectName: "planInboxToggle"; quiet: true
                        text: root.inboxExpanded ? "Hide Inbox" : "Show Inbox"
                        iconName: root.inboxExpanded ? "collapse" : "expand"
                        onClicked: root.inboxExpanded = !root.inboxExpanded
                    }
                }
                ColumnLayout {
                    visible: !section.inbox || root.inboxExpanded
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    spacing: root.theme.space(8)
                    Repeater {
                        model: section.entries.slice(section.sectionPage * 50, (section.sectionPage + 1) * 50)
                        GridLayout {
                            id: agendaRow
                            required property var modelData
                            required property int index
                            readonly property int entryIndex: section.sectionPage * 50 + index
                            readonly property bool startsDate: index === 0
                                || modelData.plannedFor !== section.entries[entryIndex - 1].plannedFor
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            Layout.topMargin: index > 0 && startsDate ? root.theme.space(12) : 0
                            columns: root.wideAgenda && !section.inbox ? 2 : 1
                            columnSpacing: root.theme.space(28); rowSpacing: root.theme.space(8)
                            ColumnLayout {
                                objectName: "planDate-" + agendaRow.modelData.id
                                visible: !section.inbox && (root.wideAgenda || agendaRow.startsDate)
                                Layout.alignment: Qt.AlignTop
                                Layout.preferredWidth: root.wideAgenda ? root.theme.space(156) : -1
                                Layout.fillWidth: !root.wideAgenda; Layout.minimumWidth: 0
                                Layout.topMargin: root.wideAgenda ? root.theme.space(14) : 0
                                spacing: root.theme.space(6)
                                SectionHeading {
                                    theme: root.theme; text: section.modelData
                                    visible: agendaRow.index === 0; Layout.fillWidth: true
                                }
                                DText {
                                    theme: root.theme; visible: agendaRow.startsDate
                                    text: section.otherDays
                                        ? Display.day(agendaRow.modelData.plannedFor, root.store.today)
                                        : Qt.formatDate(new Date(agendaRow.modelData.plannedFor + "T12:00:00"), "d MMM")
                                    color: root.theme.secondary; font.pixelSize: root.theme.small
                                    Layout.fillWidth: true
                                }
                            }
                            ActivityRow {
                                theme: root.theme; activity: agendaRow.modelData
                                Layout.fillWidth: true; Layout.minimumWidth: 0; showNavigation: true
                                actionsEnabled: !root.workspace.actionPending && !root.workspace.countdownController.logPending
                                onDetailsRequested: id => root.workspace.selectActivity(id)
                                onCompleteRequested: id => root.workspace.completeActivity(id)
                            }
                        }
                    }
                    RowLayout {
                        visible: section.entries.length > 50 || section.sectionPage > 0; Layout.fillWidth: true
                        Layout.leftMargin: root.wideAgenda && !section.inbox ? root.theme.space(184) : 0
                        DButton { theme: root.theme; text: "Previous"; iconName: "previous"; objectName: "planPrevious-" + section.modelData; enabled: section.sectionPage > 0; onClicked: section.sectionPage-- }
                        DText { theme: root.theme; text: "Page " + (section.sectionPage + 1); Layout.fillWidth: true }
                        DButton { theme: root.theme; text: "Next"; iconName: "next"; objectName: "planNext-" + section.modelData; enabled: (section.sectionPage + 1) * 50 < section.entries.length; onClicked: section.sectionPage++ }
                    }
                }
            }
        }
    }
    CalendarEventList {
        theme: root.theme; Layout.fillWidth: true; Layout.minimumWidth: 0
        visible: root.calendarController !== null && root.calendarController.configured
        events: root.calendarController ? root.calendarController.events : []
        windowStart: root.calendarController ? root.calendarController.info.windowStart : ""
        windowEnd: root.calendarController ? root.calendarController.info.windowEnd : ""
        windowLabel: root.calendarController ? root.calendarController.windowLabel : ""
        calendarName: root.calendarController ? root.calendarController.info.name : ""
        statusText: root.calendarController ? root.calendarController.statusText : ""
    }
}
