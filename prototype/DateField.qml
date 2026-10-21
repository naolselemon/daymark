pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

Item {
    id: root
    implicitWidth: openDate.implicitWidth
    implicitHeight: openDate.implicitHeight
    required property var theme
    required property string today
    property alias text: typedDate.text
    property bool allowEmpty: false
    property string fieldName: ""
    property string caption: ""
    readonly property bool calendarOpen: calendarPopup.opened
    signal textEdited()
    onActiveFocusChanged: if (activeFocus) openDate.forceActiveFocus()
    function choose(value) { text = value; textEdited(); calendarPopup.close(); }
    function showCalendar() {
        const chosen = new Date((text || today) + "T12:00:00");
        const value = isNaN(chosen.getTime()) ? new Date(today + "T12:00:00") : chosen;
        calendar.month = value.getMonth(); calendar.year = value.getFullYear();
        calendarPopup.open();
    }
    function shiftMonth(delta) {
        const date = new Date(calendar.year, calendar.month + delta, 1, 12);
        calendar.month = date.getMonth(); calendar.year = date.getFullYear();
    }
    DButton {
        id: openDate
        theme: root.theme
        objectName: root.fieldName + "Picker"
        text: root.caption || Display.day(root.text, root.today)
        Accessible.name: "Choose date, " + Display.day(root.text, root.today)
        onClicked: root.showCalendar()
    }
    Popup {
        id: calendarPopup
        objectName: root.fieldName + "Calendar"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(parent.width - root.theme.padding * 2, root.theme.space(340))
        height: Math.min(implicitHeight, parent.height - root.theme.padding * 2)
        implicitHeight: calendarBody.implicitHeight + padding * 2
        padding: root.theme.padding
        modal: true; focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle { color: root.theme.background; border.color: root.theme.border; radius: root.theme.radius }
        onClosed: openDate.forceActiveFocus()
        contentItem: ScrollView {
            contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: calendarBody
                width: parent.width
                spacing: root.theme.gap
                RowLayout {
                    Layout.fillWidth: true
                    DButton { theme: root.theme; quiet: true; text: "‹"; Accessible.name: "Previous month"; objectName: root.fieldName + "PreviousMonth"; onClicked: root.shiftMonth(-1) }
                    DText { theme: root.theme; text: calendar.title; font.bold: true; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                    DButton { theme: root.theme; quiet: true; text: "›"; Accessible.name: "Next month"; objectName: root.fieldName + "NextMonth"; onClicked: root.shiftMonth(1) }
                }
                DayOfWeekRow {
                    locale: calendar.locale
                    Layout.fillWidth: true
                    font.family: root.theme.family; font.pixelSize: root.theme.small
                    palette.text: root.theme.secondary
                }
                MonthGrid {
                    id: calendar
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.theme.space(210)
                    spacing: root.theme.space(2)
                    delegate: DButton {
                        required property var model
                        theme: root.theme; quiet: true
                        text: String(model.day)
                        width: (calendar.availableWidth - 6 * calendar.spacing) / 7
                        height: (calendar.availableHeight - 5 * calendar.spacing) / 6
                        padding: 0; leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0
                        opacity: model.month === calendar.month ? 1 : 0.4
                        selected: Qt.formatDate(model.date, "yyyy-MM-dd") === root.text
                        primary: Qt.formatDate(model.date, "yyyy-MM-dd") === root.today
                        objectName: root.fieldName + "Day-" + Qt.formatDate(model.date, "yyyy-MM-dd")
                        Accessible.name: Qt.formatDate(model.date, "dddd, d MMMM yyyy")
                        onClicked: root.choose(Qt.formatDate(model.date, "yyyy-MM-dd"))
                    }
                }
                Flow {
                    Layout.fillWidth: true; spacing: root.theme.gap
                    DButton { theme: root.theme; text: "Today"; objectName: root.fieldName + "Today"; onClicked: root.choose(root.today) }
                    DButton {
                        theme: root.theme; text: root.allowEmpty ? "Tomorrow" : "Yesterday"
                        objectName: root.fieldName + "AdjacentDay"
                        onClicked: { const day = new Date(root.today + "T12:00:00"); day.setDate(day.getDate() + (root.allowEmpty ? 1 : -1)); root.choose(Qt.formatDate(day, "yyyy-MM-dd")); }
                    }
                    DButton { theme: root.theme; text: "No date"; visible: root.allowEmpty; objectName: root.fieldName + "NoDate"; onClicked: root.choose("") }
                }
                DText { theme: root.theme; text: "Or type a date"; color: root.theme.secondary; font.pixelSize: root.theme.small }
                RowLayout {
                    Layout.fillWidth: true
                    DField { id: typedDate; theme: root.theme; objectName: root.fieldName; Accessible.name: "Date, YYYY-MM-DD"; placeholderText: "YYYY-MM-DD"; Layout.fillWidth: true; onTextEdited: root.textEdited(); onAccepted: calendarPopup.close() }
                    DButton { theme: root.theme; text: "Apply"; onClicked: { root.textEdited(); calendarPopup.close(); } }
                }
                DButton { theme: root.theme; quiet: true; text: "Close calendar"; objectName: root.fieldName + "CloseCalendar"; onClicked: calendarPopup.close() }
            }
        }
    }
}
