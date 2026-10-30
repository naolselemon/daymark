pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    required property var theme
    required property var event
    required property string day
    property string calendarName: ""
    readonly property bool compact: width < theme.space(360)
    readonly property bool continued: event.startDate < day
    readonly property string timeLabel: event.allDay ? qsTr("All day")
        : continued ? qsTr("Continues") : event.startTime
    readonly property string endLabel: event.allDay ? ""
        : event.endTimeDate > day ? qsTr("Overnight") : qsTr("Until %1").arg(event.endTime)
    implicitHeight: content.implicitHeight + theme.space(24)
    color: theme.surface
    radius: theme.radius
    objectName: "calendarEvent-" + event.id
    Accessible.role: Accessible.StaticText
    Accessible.name: (event.title || qsTr("Untitled event")) + ". " + timeLabel + ". " + endLabel
        + ". " + (calendarName || qsTr("Google Calendar")) + ". " + qsTr("Read only")

    Rectangle {
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        anchors.topMargin: root.theme.space(12); anchors.bottomMargin: root.theme.space(12)
        width: root.theme.space(2); color: root.theme.accent
    }
    GridLayout {
        id: content
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: root.theme.space(12)
        anchors.leftMargin: root.theme.space(18)
        columns: root.compact ? 1 : 2
        columnSpacing: root.theme.space(20); rowSpacing: root.theme.space(10)
        ColumnLayout {
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: root.compact ? -1 : root.theme.space(90)
            Layout.fillWidth: root.compact; Layout.minimumWidth: 0
            spacing: root.theme.space(3)
            DText {
                theme: root.theme; text: root.timeLabel
                font.pixelSize: root.event.allDay || root.continued ? root.theme.body : root.theme.heading
                font.italic: !root.event.allDay && !root.continued
                color: root.theme.accent; Layout.fillWidth: true; Layout.minimumWidth: 0
            }
            DText {
                theme: root.theme; text: root.endLabel; visible: text !== ""
                font.pixelSize: root.theme.small; color: root.theme.secondary
                Layout.fillWidth: true; Layout.minimumWidth: 0
            }
        }
        ColumnLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.alignment: Qt.AlignVCenter
            spacing: root.theme.space(8)
            DText {
                theme: root.theme; text: root.event.title || qsTr("Untitled event")
                font.bold: true; Layout.fillWidth: true; Layout.minimumWidth: 0
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: root.theme.space(6)
                DIcon {
                    name: "calendar"; color: root.theme.secondary
                    Layout.preferredWidth: root.theme.space(14); Layout.preferredHeight: root.theme.space(14)
                }
                DText {
                    theme: root.theme; text: root.calendarName || qsTr("Google Calendar")
                    font.pixelSize: root.theme.small; color: root.theme.secondary
                    Layout.fillWidth: true; Layout.minimumWidth: 0; wrapMode: Text.Wrap
                }
            }
        }
    }
}
