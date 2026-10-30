pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

Item {
    id: root
    required property var theme
    signal unlockRequested()
    function focusUnlock() { unlockButton.forceActiveFocus(Qt.TabFocusReason); }

    ScrollView {
        id: lockedScroll
        anchors.fill: parent
        contentWidth: availableWidth
        contentHeight: lockedCanvas.height
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        Item {
            id: lockedCanvas
            width: lockedScroll.availableWidth
            height: Math.max(card.implicitHeight + root.theme.space(24), root.height)
            ColumnLayout {
                id: card
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, Math.min(parent.width - root.theme.space(24), root.theme.space(400)))
                spacing: root.theme.space(12)
                DIcon {
                    name: "lock"; color: root.theme.accent
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: root.theme.space(28); Layout.preferredHeight: root.theme.space(28)
                }
                DText {
                    theme: root.theme; text: "A space that's yours."
                    font.pixelSize: root.theme.heading; font.bold: true
                    horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                }
                DText {
                    theme: root.theme
                    text: "Your days, in your own words. Unlock your diary to write a page or return to an earlier one."
                    horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                    color: root.theme.secondary
                    font.pixelSize: root.theme.body
                }
                DButton {
                    id: unlockButton
                    objectName: "diaryUnlockOpen"
                    theme: root.theme; primary: true; text: "Unlock diary"
                    iconName: "unlock"; iconOnly: false
                    Layout.alignment: Qt.AlignHCenter
                    onClicked: root.unlockRequested()
                }
                DText {
                    theme: root.theme; text: "Use your Linux account password."
                    horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                    font.pixelSize: root.theme.small; color: root.theme.secondary
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border; opacity: 0.35 }
                DText {
                    theme: root.theme
                    text: "A privacy lock, not encryption. Notes and backups remain readable on disk to someone with access to your account."
                    horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                    font.pixelSize: root.theme.small; color: root.theme.secondary
                }
            }
        }
    }
}
