pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import "Display.js" as Display

Item {
    id: root
    required property var theme
    required property var store
    property string activityId: ""
    property bool shortcutsEnabled: true
    property bool actionsEnabled: true
    readonly property bool calendarOpen: dateField.calendarOpen
    readonly property var current: store.activity(activityId)
    property string feedback: ""
    property bool failed: false
    property string loadedId: ""
    property int expectedRevision: 0
    property bool saving: false
    property string draftBaseline: ""
    property string pendingRequestId: ""
    property string pendingPayload: ""
    property int sessionPage: 0
    property bool editing: false
    property bool fullNote: false
    readonly property string draftFingerprint: JSON.stringify({
        title: titleField.text, plannedFor: dateField.text, note: noteField.text,
        tasks: taskEditor.fingerprint
    })
    readonly property bool dirty: loadedId !== "" && draftBaseline !== ""
        && (draftFingerprint !== draftBaseline || pendingRequestId !== "")
    signal backRequested()
    signal addSessionRequested(string id)
    signal timerRequested(string activityId, string taskId)
    signal logTaskRequested(string activityId, string taskId)
    signal completeRequested(string id)
    signal pinRequested(string id)
    signal editSessionRequested(var session)
    signal deleteRequested(string kind, string id, int revision, string title)
    signal saved()

    function reload(discard = false) {
        if (saving || (dirty && !discard)) return false;
        const activity = store.activity(activityId);
        loadedId = activity ? activityId : "";
        expectedRevision = activity ? activity.revision : 0;
        titleField.text = activity ? activity.title : "";
        dateField.text = activity ? activity.plannedFor : "";
        noteField.text = activity ? activity.note : "";
        taskEditor.load(activity ? activity.tasks || [] : []);
        pendingRequestId = "";
        pendingPayload = "";
        draftBaseline = draftFingerprint;
        feedback = "";
        failed = false;
        return true;
    }

    function discardChanges() {
        const discarded = reload(true);
        if (discarded) editing = false;
        return discarded;
    }

    function save() {
        if (!current || saving || !dirty) return;
        if (loadedId !== activityId) {
            failed = true;
            feedback = "Your previous draft is retained. Return to that activity to save it, or discard the draft.";
            return;
        }
        failed = true;
        if (!titleField.text.trim()) {
            feedback = "Enter a title. Your other changes are retained.";
            titleField.forceActiveFocus();
            return;
        }
        if (!store.validDate(dateField.text.trim(), true)) {
            feedback = "Choose a date, or No date for Inbox.";
            dateField.forceActiveFocus();
            return;
        }
        const fields = {title: titleField.text.trim(), plannedFor: dateField.text.trim(),
            note: noteField.text, tasks: taskEditor.tasks, expectedRevision: expectedRevision};
        const payload = JSON.stringify({activityId: activityId, fields: fields});
        if (payload !== pendingPayload || !pendingRequestId) {
            pendingRequestId = store.newRequestId();
            pendingPayload = payload;
        }
        saving = true;
        failed = false;
        feedback = "Saving…";
        store.updateActivity(activityId, fields, function(ok, result, error) {
            saving = false;
            if (!ok) {
                failed = true;
                feedback = (error && error.message ? error.message : "Could not save changes.")
                    + (error && error.code === "conflict"
                        ? " Your draft is retained. Discard draft reloads the saved version."
                        : " Your draft is retained; retry below.");
                return;
            }
            reload(true);
            editing = false;
            feedback = "Saved";
            saved();
        }, pendingRequestId);
    }

    onActivityIdChanged: { sessionPage = 0; editing = false; fullNote = false; reload(); }
    onCurrentChanged: {
        if (!dirty && !saving)
            reload();
    }
    onDirtyChanged: {
        if (dirty && !failed && !saving) feedback = "";
    }
    Component.onCompleted: reload()

    Shortcut { sequences: ["Ctrl+Return", "Ctrl+Enter", "Ctrl+S"]; enabled: root.visible && root.editing && !root.saving && root.shortcutsEnabled && !root.calendarOpen; onActivated: root.save() }
    ColumnLayout {
        anchors.fill: parent; spacing: root.theme.space(18)
        RowLayout {
            Layout.fillWidth: true
            DButton { theme: root.theme; quiet: true; objectName: "detailBack"; text: "Back"; iconName: "back"; enabled: !root.saving; onClicked: root.backRequested() }
            Item { Layout.fillWidth: true }
            DButton { theme: root.theme; quiet: true; objectName: "detailEdit"; text: "Edit activity"; iconName: "edit"; visible: !!root.current && !root.editing; onClicked: { root.editing = true; titleField.forceActiveFocus(); } }
        }
        ScrollView {
            id: scroll
            objectName: "activityDetailScroll"
            Layout.fillWidth: true; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: scroll.availableWidth; spacing: root.theme.space(24)
                Rectangle {
                    objectName: "activityContentCard"
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    implicitHeight: activityContent.implicitHeight + root.theme.space(40)
                    color: root.theme.surface
                    radius: root.theme.radius
                    border.color: Qt.rgba(root.theme.border.r, root.theme.border.g, root.theme.border.b, root.theme.border.a * 0.4)
                    ColumnLayout {
                        id: activityContent
                        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                        anchors.margins: root.theme.space(20)
                        spacing: root.theme.space(28)
                        DText { theme: root.theme; text: "This activity is no longer available."; visible: !root.current; Layout.fillWidth: true }
                        ColumnLayout {
                            visible: !!root.current && !root.editing; Layout.fillWidth: true; spacing: root.theme.space(18)
                            DText { theme: root.theme; text: root.current ? root.current.title : ""; font.pixelSize: root.theme.pageTitle; font.bold: true; font.italic: true; Layout.fillWidth: true }
                            DText {
                                theme: root.theme; Layout.fillWidth: true; color: root.theme.secondary
                                text: !root.current ? "" : root.current.status === "done" ? "Completed " + Display.day(root.current.completedDate, root.store.today)
                                    : root.current.plannedFor ? "Planned for " + Display.day(root.current.plannedFor, root.store.today) : "An idea for another day"
                            }
                            DText { id: overviewNote; theme: root.theme; text: root.current ? root.current.note : ""; visible: text !== ""; Layout.fillWidth: true; maximumLineCount: root.fullNote ? 2147483647 : 6; elide: Text.ElideRight }
                            DButton { theme: root.theme; quiet: true; text: root.fullNote ? "Show less" : "Read full note"; iconName: root.fullNote ? "collapse" : "expand"; visible: overviewNote.truncated || root.fullNote; onClicked: root.fullNote = !root.fullNote }
                            Flow {
                                Layout.fillWidth: true; spacing: root.theme.gap
                                DButton { theme: root.theme; objectName: "detailAddSession"; text: "Log activity"; iconName: "log"; shortcutHint: "Ctrl+L"; primary: true; onClicked: root.addSessionRequested(root.activityId) }
                                DButton { theme: root.theme; quiet: true; objectName: "detailTimer"; text: qsTr("Start activity timer"); iconName: "timer"; enabled: root.actionsEnabled; onClicked: root.timerRequested(root.activityId, "") }
                                DButton { theme: root.theme; quiet: true; objectName: "detailComplete"; enabled: root.actionsEnabled; text: root.current && root.current.status === "done" ? "Reopen" : "Mark done"; iconName: root.current && root.current.status === "done" ? "restore" : "check"; onClicked: root.completeRequested(root.activityId) }
                                DButton { theme: root.theme; quiet: true; objectName: "detailPin"; enabled: root.actionsEnabled; text: root.current && root.current.pinned ? "Unpin activity" : "Pin activity"; iconName: root.current && root.current.pinned ? "unpin" : "pin"; onClicked: root.pinRequested(root.activityId) }
                            }
                            DText { theme: root.theme; visible: !!root.current && root.current.pinned; text: "Pinned · quick access from Today and Plan, on every date."; font.pixelSize: root.theme.small; color: root.theme.secondary; Layout.fillWidth: true }
                        }
                        ColumnLayout {
                            visible: !!root.current && root.editing; Layout.fillWidth: true; spacing: root.theme.space(14); enabled: !root.saving
                            DText { theme: root.theme; text: "Edit activity"; font.pixelSize: root.theme.title; Layout.fillWidth: true }
                            DText { theme: root.theme; text: "Activity" }
                            DField { id: titleField; theme: root.theme; objectName: "detailTitle"; Layout.fillWidth: true }
                            DText { theme: root.theme; text: "Planned for" }
                            DateField { id: dateField; theme: root.theme; today: root.store.today; allowEmpty: true; fieldName: "detailDate"; Layout.fillWidth: true }
                            TaskEditor { id: taskEditor; theme: root.theme; namePrefix: "detailTask"; Layout.fillWidth: true }
                            DText { theme: root.theme; text: qsTr("Description"); color: root.theme.secondary }
                            DArea { id: noteField; theme: root.theme; objectName: "detailNote"; Layout.fillWidth: true; Layout.preferredHeight: Math.max(implicitHeight, root.theme.space(120)); placeholderText: "Anything you'd like to remember" }
                        }
                        ColumnLayout {
                            objectName: "activityTasks"
                            visible: !!root.current && !root.editing
                            Layout.fillWidth: true
                            spacing: root.theme.space(8)
                            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                            RowLayout {
                                Layout.fillWidth: true
                                SectionHeading { theme: root.theme; text: qsTr("Tasks"); Layout.fillWidth: true }
                                DButton {
                                    theme: root.theme
                                    objectName: "detailAddTask"
                                    text: qsTr("Add task")
                                    iconName: "add"
                                    quiet: true
                                    enabled: root.actionsEnabled
                                    onClicked: { root.editing = true; taskEditor.focusAdd(); }
                                }
                            }
                            Repeater {
                                model: root.current ? root.current.tasks || [] : []
                                ColumnLayout {
                                    id: reusableTask
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: root.theme.space(8)
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: root.theme.space(8)
                                        DText {
                                            theme: root.theme
                                            Layout.fillWidth: true
                                            Layout.minimumWidth: 0
                                            text: reusableTask.modelData.title
                                            wrapMode: Text.Wrap
                                        }
                                        DButton {
                                            theme: root.theme
                                            objectName: "detailTaskTimer-" + reusableTask.modelData.id
                                            text: qsTr("Start timer for %1").arg(reusableTask.modelData.title)
                                            iconName: "timer"
                                            quiet: true
                                            enabled: root.actionsEnabled
                                            onClicked: root.timerRequested(root.activityId, reusableTask.modelData.id)
                                        }
                                        DButton {
                                            theme: root.theme
                                            objectName: "detailTaskLog-" + reusableTask.modelData.id
                                            text: qsTr("Log %1").arg(reusableTask.modelData.title)
                                            iconName: "log"
                                            quiet: true
                                            enabled: root.actionsEnabled
                                            onClicked: root.logTaskRequested(root.activityId, reusableTask.modelData.id)
                                        }
                                    }
                                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.theme.border }
                                }
                            }
                        }
                        ColumnLayout {
                            objectName: "activityEntries"
                            visible: !!root.current && !root.editing; Layout.fillWidth: true; spacing: root.theme.space(18)
                            RowLayout {
                                Layout.fillWidth: true
                                SectionHeading { theme: root.theme; text: qsTr("Entries"); Layout.fillWidth: true }
                                DButton { theme: root.theme; quiet: true; objectName: "detailLogEntry"; text: qsTr("Log entry"); iconName: "log"; onClicked: root.addSessionRequested(root.activityId) }
                            }
                            DText { theme: root.theme; text: "Nothing logged yet."; color: root.theme.secondary; visible: root.store.sessionsFor(root.activityId).length === 0; Layout.fillWidth: true }
                            Repeater {
                                model: root.visible ? root.store.sessionsFor(root.activityId).slice(root.sessionPage * 30, (root.sessionPage + 1) * 30) : []
                                ColumnLayout {
                                    id: entry
                                    required property var modelData
                                    Layout.fillWidth: true; spacing: root.theme.space(8)
                                    RowLayout {
                                        Layout.fillWidth: true
                                        DText { theme: root.theme; text: Display.day(entry.modelData.date, root.store.today); font.pixelSize: root.theme.small; color: root.theme.secondary; Layout.fillWidth: true }
                                        DButton { theme: root.theme; quiet: true; objectName: "sessionEdit-" + entry.modelData.id; text: "Edit"; iconName: "edit"; onClicked: root.editSessionRequested(entry.modelData) }
                                        DButton { theme: root.theme; quiet: true; objectName: "sessionDelete-" + entry.modelData.id; text: "Delete"; iconName: "delete"; onClicked: root.deleteRequested("session", entry.modelData.id, entry.modelData.revision, "Entry · " + Display.day(entry.modelData.date, root.store.today)) }
                                    }
                                    DText { theme: root.theme; Layout.fillWidth: true; color: root.theme.accent; text: (entry.modelData.tasks || []).map(task => task.title).join(" · "); visible: text !== ""; wrapMode: Text.Wrap }
                                    DText { theme: root.theme; Layout.fillWidth: true; text: entry.modelData.note || ((entry.modelData.tasks || []).length ? "" : "Activity logged."); visible: text !== ""; wrapMode: Text.Wrap }
                                }
                            }
                            RowLayout {
                                visible: root.store.sessionsFor(root.activityId).length > 30 || root.sessionPage > 0; Layout.fillWidth: true
                                DButton { theme: root.theme; objectName: "detailSessionsPrevious"; text: "Previous"; iconName: "previous"; enabled: root.sessionPage > 0; onClicked: root.sessionPage-- }
                                DText { theme: root.theme; text: "Page " + (root.sessionPage + 1); Layout.fillWidth: true }
                                DButton { theme: root.theme; objectName: "detailSessionsNext"; text: "Next"; iconName: "next"; enabled: (root.sessionPage + 1) * 30 < root.store.sessionsFor(root.activityId).length; onClicked: root.sessionPage++ }
                            }
                            DButton { theme: root.theme; quiet: true; objectName: "detailDelete"; text: "Delete activity"; iconName: "delete"; font.pixelSize: root.theme.small; enabled: !!root.current; onClicked: root.deleteRequested("activity", root.activityId, root.current.revision, root.current.title) }
                        }
                    }
                }
                Loader {
                    objectName: "inlineActivityInsights"
                    Layout.fillWidth: true
                    active: root.visible && !!root.current && !root.editing && !!root.store.insights
                    visible: active
                    sourceComponent: ActivityInsights {
                        theme: root.theme
                        stats: root.store.insights.byActivity[root.activityId]; days: root.store.insights.days
                    }
                }
            }
        }
        DText { theme: root.theme; objectName: "detailFeedback"; text: root.feedback; visible: text !== ""; color: root.failed ? root.theme.urgent : root.theme.secondary; Layout.fillWidth: true }
        RowLayout {
            visible: root.editing; Layout.fillWidth: true
            DButton { theme: root.theme; quiet: true; objectName: "detailDiscard"; text: root.dirty ? "Discard changes" : "Cancel"; enabled: !root.saving; onClicked: root.discardChanges() }
            Item { Layout.fillWidth: true }
            DButton { theme: root.theme; objectName: "detailSave"; text: root.saving ? "Saving…" : root.failed ? "Retry save" : "Save changes"; iconName: "save"; shortcutHint: "Ctrl+S · Ctrl+Enter"; primary: true; enabled: root.dirty && !root.saving && root.store.loaded; onClicked: root.save() }
        }
    }
}
