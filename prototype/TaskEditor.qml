pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var theme
    property string namePrefix: "taskEditor"
    property int generation: 0
    readonly property string fingerprint: {
        const revision = generation;
        return JSON.stringify([revision >= 0 ? savedRows() : [], addField.text]);
    }
    readonly property var tasks: {
        const revision = generation;
        const rows = revision >= 0 ? savedRows() : [];
        if (addField.text.trim()) rows.push({title: addField.text.trim()});
        return rows;
    }
    spacing: theme.space(8)

    function savedRows() {
        const rows = [];
        for (let i = 0; i < definitions.count; i++) {
            const row = definitions.get(i);
            const task = {title: row.title};
            if (row.taskId) task.id = row.taskId;
            rows.push(task);
        }
        return rows;
    }
    function load(tasks) {
        definitions.clear();
        for (const task of tasks || []) definitions.append({taskId: task.id || "", title: task.title});
        addField.text = "";
        generation++;
    }
    function focusAdd() { addField.forceActiveFocus(Qt.TabFocusReason); }
    function addTask() {
        if (!addField.text.trim()) { focusAdd(); return; }
        definitions.append({taskId: "", title: addField.text.trim()});
        addField.text = "";
        generation++;
        focusAdd();
    }

    ListModel { id: definitions }
    DText { theme: root.theme; text: qsTr("Tasks"); font.italic: true; Layout.fillWidth: true }
    Repeater {
        model: definitions
        RowLayout {
            id: taskRow
            required property int index
            required property string taskId
            required property string title
            Layout.fillWidth: true
            spacing: root.theme.space(8)
            DField {
                theme: root.theme
                objectName: root.namePrefix + "Title-" + taskRow.index
                Accessible.name: qsTr("Task title")
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                text: taskRow.title
                onTextEdited: {
                    definitions.setProperty(taskRow.index, "title", text);
                    root.generation++;
                }
                onAccepted: root.focusAdd()
            }
            DButton {
                theme: root.theme
                objectName: root.namePrefix + "Remove-" + taskRow.index
                text: qsTr("Remove task")
                iconName: "close"
                quiet: true
                onClicked: { definitions.remove(taskRow.index); root.generation++; }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: root.theme.space(8)
        DField {
            id: addField
            theme: root.theme
            objectName: root.namePrefix + "AddTitle"
            Accessible.name: qsTr("Add a task")
            placeholderText: qsTr("Add a task…")
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Keys.onReturnPressed: event => { if (!event.isAutoRepeat) root.addTask(); }
            Keys.onEnterPressed: event => { if (!event.isAutoRepeat) root.addTask(); }
        }
        DButton {
            theme: root.theme
            objectName: root.namePrefix + "Add"
            text: qsTr("Add task")
            iconName: "add"
            quiet: true
            onClicked: root.addTask()
        }
    }
}
