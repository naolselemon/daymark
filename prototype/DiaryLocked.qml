pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Shapes

Item {
    id: root
    required property var theme
    signal unlockRequested()
    function focusUnlock() { unlockButton.forceActiveFocus(Qt.TabFocusReason); }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        Item {
            width: parent.width
            implicitHeight: Math.max(card.implicitHeight + root.theme.space(48), root.height)
            ColumnLayout {
                id: card
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(parent.width - root.theme.space(24), root.theme.space(460))
                spacing: root.theme.space(22)
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter
                    implicitWidth: root.theme.space(72); implicitHeight: width
                    radius: root.theme.radius
                    color: root.theme.accentSurface
                    Shape {
                        anchors.centerIn: parent
                        width: 32; height: 36
                        scale: root.theme.space(32) / 32
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            fillColor: "transparent"; strokeColor: root.theme.accent
                            strokeWidth: 1.6; capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                            PathSvg { path: "M8 16 V10 A8 8 0 0 1 24 10 V16 M6 16 H26 Q28 16 28 18 V31 Q28 33 26 33 H6 Q4 33 4 31 V18 Q4 16 6 16 Z M16 23 V27" }
                        }
                    }
                }
                DText {
                    theme: root.theme; text: "A space that's yours."
                    font.pixelSize: root.theme.pageTitle; font.bold: true; font.italic: true
                    horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                }
                DText {
                    theme: root.theme
                    text: "Your days, in your own words. Unlock your diary to write a page or return to an earlier one."
                    horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                    color: root.theme.secondary
                    font.italic: true
                }
                DButton {
                    id: unlockButton
                    objectName: "diaryUnlockOpen"
                    theme: root.theme; primary: true; text: "Unlock diary"
                    iconName: "unlock"
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
