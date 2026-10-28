pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var theme
    property var tasks: []
    property var selectedIds: []
    property string namePrefix: "taskSelection"
    signal selectionEdited(var ids)
    spacing: theme.space(4)
    visible: tasks.length > 0

    DText { theme: root.theme; text: qsTr("Tasks"); font.italic: true; Layout.fillWidth: true }
    Repeater {
        model: root.tasks
        DCheckBox {
            id: choice
            required property var modelData
            theme: root.theme
            objectName: root.namePrefix + "-" + modelData.id
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: modelData.title
            checked: root.selectedIds.indexOf(modelData.id) >= 0
            contentItem: DText {
                theme: root.theme
                text: choice.text
                wrapMode: Text.Wrap
                leftPadding: choice.indicator.width + choice.spacing
                verticalAlignment: Text.AlignVCenter
                color: choice.checked ? root.theme.accent : root.theme.foreground
            }
            onToggled: {
                const next = root.selectedIds.filter(id => id !== modelData.id);
                if (checked) next.push(modelData.id);
                root.selectionEdited(next);
            }
        }
    }
    DText {
        theme: root.theme
        Layout.fillWidth: true
        text: qsTr("Choose any, or just write below.")
        color: root.theme.secondary
        font.pixelSize: root.theme.small
    }
}
