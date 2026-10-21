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
    anchors.centerIn: parent
    width: Math.min(parent.width - theme.space(32), theme.space(760))
    height: Math.min(parent.height - theme.space(32), implicitHeight)
    implicitHeight: body.implicitHeight + padding * 2
    padding: theme.space(24)
    background: Rectangle { color: root.theme.background; radius: root.theme.radius; border.color: root.theme.border }
    onOpened: scroll.forceActiveFocus(Qt.PopupFocusReason)

    function requestDismiss() { close(); return true; }

    contentItem: ColumnLayout {
        id: body
        spacing: root.theme.space(20)
        ColumnLayout {
            Layout.fillWidth: true; spacing: root.theme.space(8)
            DText { theme: root.theme; text: "Keyboard shortcuts"; font.pixelSize: root.theme.title; font.bold: true; Layout.fillWidth: true }
            DText { theme: root.theme; text: "A few keys for planning, writing and finding things."; color: root.theme.secondary; Layout.fillWidth: true }
        }
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
                            {keys: "Ctrl+Enter", action: "Save a form"}
                        ]},
                        {title: "Find your way", entries: [
                            {keys: "Ctrl+1", action: "Today"},
                            {keys: "Ctrl+2", action: "Plan"},
                            {keys: "Ctrl+3", action: "History"},
                            {keys: "Ctrl+Shift+J", action: "All diary entries"},
                            {keys: "Ctrl+F", action: "Search History"}
                        ]},
                        {title: "Journal & tools", entries: [
                            {keys: "Ctrl+,", action: "Data & Safety"},
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
                        implicitHeight: groupContent.implicitHeight + root.theme.space(32)
                        color: root.theme.surface
                        radius: root.theme.radius
                        ColumnLayout {
                            id: groupContent
                            anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                            anchors.margins: root.theme.space(16)
                            spacing: root.theme.space(14)
                            DText {
                                theme: root.theme; text: groupCard.modelData.title
                                font.pixelSize: root.theme.heading; font.bold: true
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
                theme: root.theme; Layout.fillWidth: true; font.pixelSize: root.theme.small; color: root.theme.secondary
                text: "Diary autosaves. Close dialogs before switching views.\nText keeps its normal Undo and Redo."
            }
            DButton { theme: root.theme; text: "Close"; objectName: "shortcutsClose"; onClicked: root.close() }
        }
    }
}
