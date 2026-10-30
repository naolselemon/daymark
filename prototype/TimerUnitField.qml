import QtQuick
import QtQuick.Controls.Basic
import "Focus.js" as Focus

TextField {
    id: root
    required property var theme
    required property string value
    required property string unitName
    required property bool editable
    property bool liveDisplay: false
    property int maximum: 59
    property string draft: ""
    property bool publishing: false
    property var unitGroup: null
    property int unitIndex: 0
    readonly property bool validUnit: draft === "" || Number(draft) <= maximum
    signal edited(string value)
    signal submitted()

    text: draft
    readOnly: !editable
    // Keep the current tab stop until focus leaves; Qt cannot remove it while focused.
    focusPolicy: editable || activeFocus ? Qt.StrongFocus : Qt.NoFocus
    selectByMouse: true
    hoverEnabled: true
    inputMethodHints: Qt.ImhDigitsOnly | Qt.ImhNoPredictiveText
    // Keep invalid ranges visible instead of turning an attempted 60 into 6.
    // Do not use maximumLength: oversized pastes must be rejected, not truncated.
    validator: RegularExpressionValidator { regularExpression: /^[0-9]{0,2}$/ }
    font.family: theme.family
    color: validUnit || !editable ? theme.foreground : theme.urgent
    selectionColor: theme.fill("selection")
    selectedTextColor: theme.foreground
    leftPadding: theme.space(6)
    rightPadding: theme.space(6)
    topPadding: theme.space(4)
    bottomPadding: theme.space(4)
    horizontalAlignment: Text.AlignHCenter
    implicitWidth: Math.ceil(metrics.advanceWidth) + leftPadding + rightPadding + 1
    implicitHeight: Math.ceil(metrics.height) + topPadding + bottomPadding
    TextMetrics { id: metrics; font: root.font; text: "00" }

    Component.onCompleted: draft = value
    onValueChanged: if (!publishing) draft = value
    onTextEdited: {
        if (!editable) {
            draft = value;
            return;
        }
        // The canonical value updates synchronously, but the typing field keeps
        // its unpadded text and cursor; the other readout follows that value.
        publishing = true;
        draft = text;
        edited(text);
        publishing = false;
    }
    // Keep keyboard ownership during a poll or status change. A read-only field
    // must not hand the same Enter/Backspace gesture to an application shortcut.
    onLiveDisplayChanged: if (liveDisplay) draft = value
    onActiveFocusChanged: {
        if (activeFocus) Qt.callLater(() => {
            if (!root.activeFocus || !root.editable) return;
            root.selectAll();
            Focus.reveal(root);
        });
    }
    onAccepted: if (editable) submitted()
    Keys.onPressed: event => {
        if (!editable || event.modifiers !== Qt.NoModifier
                || (event.key !== Qt.Key_Left && event.key !== Qt.Key_Right)) return;
        const fullSelection = text.length > 0 && selectionStart === 0 && selectionEnd === text.length;
        const boundary = selectionStart === selectionEnd
            && cursorPosition === (event.key === Qt.Key_Left ? 0 : text.length);
        const adjacent = unitGroup ? unitGroup.itemAt(unitIndex + (event.key === Qt.Key_Left ? -1 : 1)) : null;
        const target = adjacent ? adjacent.unit : null;
        if ((!fullSelection && !boundary) || !target || !target.editable || !target.visible || !target.enabled) return;
        target.forceActiveFocus(Qt.OtherFocusReason);
        event.accepted = true;
    }
    background: Rectangle {
        x: 1
        y: 1
        width: parent.width - 2
        height: parent.height - 2
        color: root.editable && (root.activeFocus || root.hovered) ? root.theme.controlSurface : "transparent"
        radius: Math.min(root.theme.radius, root.theme.space(4))
        border.width: root.editable && (root.activeFocus || root.hovered || !root.validUnit) ? 1 : 0
        border.color: !root.validUnit ? root.theme.urgent : root.activeFocus ? root.theme.accent : root.theme.border
    }
    Accessible.name: unitName
    Accessible.description: qsTr("Enter a value from 0 to %1").arg(maximum)
}
