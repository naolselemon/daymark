pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "Display.js" as Display

ColumnLayout {
    id: root
    required property var workspace
    readonly property var theme: workspace.theme
    readonly property var store: workspace.store
    readonly property var months: {
        if (!visible || store.historyLoading || store.historyError) return [];
        const groups = Object.create(null);
        store.historyNotes.forEach(note => {
            const month = note.date.slice(0, 7);
            if (!groups[month]) groups[month] = {month: month, notes: []};
            groups[month].notes.push(note);
        });
        return Object.keys(groups).sort().reverse().map(month => groups[month]);
    }
    spacing: theme.space(28)
    Repeater {
        model: root.months
        ColumnLayout {
            id: monthGroup
            required property var modelData
            Layout.fillWidth: true
            spacing: root.theme.space(12)
            SectionHeading {
                theme: root.theme
                text: Qt.formatDate(new Date(monthGroup.modelData.month + "-01T12:00:00"), "MMMM yyyy")
                Layout.fillWidth: true
            }
            Repeater {
                model: monthGroup.modelData.notes
                DButton {
                    id: diaryCard
                    required property var modelData
                    readonly property string excerpt: modelData.body.trim()
                    theme: root.theme
                    quiet: true
                    Layout.fillWidth: true
                    objectName: "diaryOpen-" + modelData.date
                    padding: root.theme.space(20)
                    implicitHeight: diaryContent.implicitHeight + topPadding + bottomPadding
                    Accessible.name: "Diary, " + Display.day(modelData.date) + ", open to read or edit"
                    background: Rectangle {
                        color: diaryCard.down ? root.theme.fill("pressed") : diaryCard.hovered ? root.theme.accentSurface : root.theme.surface
                        radius: root.theme.radius
                        border.color: diaryCard.activeFocus ? root.theme.accent : root.theme.border
                        border.width: diaryCard.activeFocus ? Math.max(1, root.theme.strokeWidth("focus")) : 0
                    }
                    contentItem: Column {
                        id: diaryContent
                        spacing: root.theme.space(12)
                        DText {
                            theme: root.theme
                            text: Display.day(diaryCard.modelData.date)
                            font.pixelSize: root.theme.heading
                            width: parent.width
                        }
                        DText {
                            theme: root.theme
                            text: diaryCard.excerpt || "An empty page, ready when you are."
                            color: diaryCard.excerpt ? root.theme.foreground : root.theme.secondary
                            maximumLineCount: 4
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }
                    onClicked: root.workspace.openDiary(modelData.date)
                }
            }
        }
    }
}
