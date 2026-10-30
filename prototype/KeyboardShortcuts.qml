pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Popup {
    id: root
    required property var theme
    objectName: "keyboardShortcutsDialog"
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    x: 0; y: 0
    width: parent ? parent.width : theme.space(480)
    height: parent ? parent.height : theme.space(760)
    implicitHeight: body.implicitHeight + padding * 2
    padding: theme.space(16)
    background: Rectangle { color: root.theme.background; radius: root.theme.radius }
    onOpened: scroll.forceActiveFocus(Qt.PopupFocusReason)

    function requestDismiss() { close(); return true; }

    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(12)
        RowLayout {
            Layout.fillWidth: true; spacing: root.theme.space(8)
            DButton { theme: root.theme; text: qsTr("Back"); iconName: "back"; quiet: true; onClicked: root.close() }
            DText { theme: root.theme; text: qsTr("Keyboard shortcuts"); font.pixelSize: root.theme.heading; font.bold: true; Layout.fillWidth: true }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
        ScrollView {
            id: scroll
            focusPolicy: Qt.StrongFocus
            padding: root.theme.space(4)
            background: Rectangle { color: "transparent"; radius: root.theme.radius; border.color: root.theme.accent; border.width: scroll.visualFocus ? 1 : 0 }
            Keys.onPressed: event => {
                if (event.key !== Qt.Key_PageDown && event.key !== Qt.Key_PageUp) return;
                const direction = event.key === Qt.Key_PageDown ? 1 : -1;
                const bar = scroll.ScrollBar.vertical;
                bar.position = Math.max(0, Math.min(1 - bar.size, bar.position + direction * bar.size));
                event.accepted = true;
            }
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.preferredHeight: groups.implicitHeight
            Layout.minimumHeight: root.theme.space(80)
            contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            GridLayout {
                id: groups
                width: scroll.availableWidth
                columns: width >= root.theme.space(640) ? 2 : 1
                columnSpacing: root.theme.space(16)
                rowSpacing: root.theme.space(16)
                uniformCellWidths: true
                Repeater {
                    model: [
                        {title: "Create & write", entries: [
                            {keys: "Ctrl+N", action: "Plan an activity"},
                            {keys: "Ctrl+L", action: "Log an activity"},
                            {keys: "Ctrl+J", action: "Write today's diary"},
                            {keys: "Ctrl+S", action: "Save form or diary"},
                            {keys: "Ctrl+Enter", action: "Add plan or save a form"}
                        ]},
                        {title: "Consecutive plans", entries: [
                            {keys: "Enter", action: "Title → date → note → Add plan"},
                            {keys: "Space", action: "Open the focused date's calendar"},
                            {keys: "Shift+Enter", action: "New line in a plan note"},
                            {keys: "Ctrl+Enter / Ctrl+S", action: "Add plan from any field"}
                        ]},
                        {title: "Find your way", entries: [
                            {keys: "Ctrl+1", action: "Timer"},
                            {keys: "Ctrl+2", action: "Today"},
                            {keys: "Ctrl+3", action: "Plan"},
                            {keys: "Ctrl+4", action: "History"},
                            {keys: "Ctrl+5", action: "Diary"},
                            {keys: "Ctrl+Shift+J", action: "Browse diary"},
                            {keys: "Ctrl+F", action: "Search Diary when there, otherwise History"}
                        ]},
                        {title: "Journal & tools", entries: [
                            {keys: "Ctrl+Shift+L", action: "Lock Diary"},
                            {keys: "Ctrl+,", action: "Settings"},
                            {keys: "Ctrl+/", action: "Keyboard shortcuts"},
                            {keys: "Esc", action: "Close popup or go back"}
                        ]},
                        {title: "Move through controls", entries: [
                            {keys: "Tab / Shift+Tab", action: "Next / previous"},
                            {keys: "Space", action: "Use focused control"},
                            {keys: "PgUp / PgDn", action: "Scroll this guide"}
                        ]}
                    ]
                    Rectangle {
                        id: groupCard
                        required property var modelData
                        Layout.fillWidth: true; Layout.fillHeight: true
                        Layout.minimumWidth: 0
                        implicitHeight: groupContent.implicitHeight + root.theme.space(16)
                        color: "transparent"
                        radius: root.theme.radius
                        ColumnLayout {
                            id: groupContent
                            anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                            anchors.margins: root.theme.space(8)
                            spacing: root.theme.space(8)
                            DText {
                                theme: root.theme; text: groupCard.modelData.title
                                font.pixelSize: root.theme.heading; font.bold: true; font.italic: true
                                Layout.fillWidth: true
                            }
                            Repeater {
                                model: groupCard.modelData.entries
                                RowLayout {
                                    id: shortcutRow
                                    required property var modelData
                                    Layout.fillWidth: true; spacing: root.theme.space(12)
                                    DText {
                                        theme: root.theme; text: shortcutRow.modelData.action
                                        Layout.fillWidth: true; Layout.minimumWidth: 0
                                        font.pixelSize: root.theme.small
                                    }
                                    Keycap { theme: root.theme; text: shortcutRow.modelData.keys }
                                }
                            }
                        }
                    }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: root.theme.space(16)
            DText {
                theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small; font.italic: true; color: root.theme.secondary
                text: "Adding a plan keeps its date and starts a fresh title. Done closes the form; unsaved drafts ask before discarding.\nDiary autosaves. Text keeps its normal Undo and Redo."
            }
            DButton { theme: root.theme; text: "Close"; iconName: "close"; objectName: "shortcutsClose"; onClicked: root.close() }
        }
    }
}
