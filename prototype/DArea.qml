import QtQuick
import QtQuick.Controls.Basic
import "Focus.js" as Focus

TextArea {
    id: root
    required property var theme
    property bool framed: true
    font.family: theme.family
    font.pixelSize: theme.body
    color: theme.foreground
    placeholderTextColor: theme.secondary
    selectionColor: theme.fill("selection")
    selectedTextColor: theme.foreground
    textFormat: TextEdit.PlainText
    wrapMode: TextEdit.Wrap
    selectByMouse: true
    padding: Math.max(theme.source.spacing["input-padding-y"], theme.space(14))
    onActiveFocusChanged: { if (activeFocus) Qt.callLater(() => Focus.reveal(root)); }
    Keys.onTabPressed: event => {
        root.nextItemInFocusChain(true).forceActiveFocus(Qt.TabFocusReason);
        event.accepted = true;
    }
    Keys.onBacktabPressed: event => {
        root.nextItemInFocusChain(false).forceActiveFocus(Qt.BacktabFocusReason);
        event.accepted = true;
    }
    background: Rectangle {
        // Keep the focus outline inside ancestor scroll-view clipping.
        anchors.fill: parent
        anchors.margins: root.theme.space(1)
        color: root.framed ? root.theme.controlSurface : "transparent"
        radius: root.theme.radius
        border.color: root.theme.accent
        border.width: root.activeFocus ? Math.max(1, root.theme.strokeWidth("focus")) : 0
    }
    Accessible.name: placeholderText
}
