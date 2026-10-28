pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import "Focus.js" as Focus

ComboBox {
    id: root
    required property var theme
    property int acknowledgedIndex: -1
    signal selectionRequested(int index)
    currentIndex: acknowledgedIndex
    displayText: acknowledgedIndex >= 0 && model ? model[acknowledgedIndex] : ""
    onActivated: index => {
        // Native selection is provisional until persistence acknowledges it.
        currentIndex = Qt.binding(() => root.acknowledgedIndex);
        selectionRequested(index);
    }
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    font.family: theme.family
    font.pixelSize: theme.body
    padding: theme.space(10)
    rightPadding: theme.space(36)
    implicitWidth: theme.space(190)
    implicitHeight: Math.max(theme.space(44), contentItem.implicitHeight + topPadding + bottomPadding)
    opacity: enabled ? 1 : 0.45
    onActiveFocusChanged: if (activeFocus) Qt.callLater(() => Focus.reveal(root))
    contentItem: DText {
        theme: root.theme
        text: root.displayText
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        wrapMode: Text.NoWrap
    }
    indicator: DIcon {
        name: "expand"; color: root.theme.secondary
        width: root.theme.space(18); height: width
        x: root.width - width - root.theme.space(10)
        y: (root.height - height) / 2
    }
    background: Rectangle {
        radius: root.theme.radius
        color: root.down ? root.theme.fill("pressed") : root.hovered ? root.theme.fill("hover-cursor") : "transparent"
        border.color: root.visualFocus ? root.theme.accent : root.theme.border
        border.width: root.visualFocus ? Math.max(1, root.theme.strokeWidth("focus")) : 1
    }
    delegate: ItemDelegate {
        id: option
        required property int index
        required property var modelData
        width: root.popup.availableWidth
        implicitHeight: Math.max(root.theme.space(44), contentItem.implicitHeight + topPadding + bottomPadding)
        padding: root.theme.space(10)
        highlighted: root.highlightedIndex === index
        contentItem: DText { theme: root.theme; text: option.modelData }
        background: Rectangle {
            radius: root.theme.radius
            color: option.highlighted ? root.theme.accentSurface : "transparent"
            border.color: root.theme.accent
            border.width: option.highlighted ? 1 : 0
        }
    }
    popup: Popup {
        y: root.height
        width: root.width
        padding: root.theme.space(4)
        implicitHeight: Math.min(options.contentHeight + padding * 2, root.theme.space(240))
        contentItem: ListView {
            id: options
            clip: true
            implicitHeight: contentHeight
            model: root.popup.visible ? root.delegateModel : null
            currentIndex: root.highlightedIndex
            highlightMoveDuration: 0
            ScrollIndicator.vertical: ScrollIndicator { }
        }
        background: Rectangle {
            color: root.theme.background
            radius: root.theme.radius
            border.color: root.theme.border
        }
    }
}
