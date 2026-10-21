pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var workspace
    readonly property var theme: workspace.theme
    readonly property var entries: workspace.pinnedActivities
    property int page: 0
    readonly property int pageCount: Math.max(1, Math.ceil(entries.length / 6))
    onPageCountChanged: page = Math.min(page, pageCount - 1)
    visible: entries.length > 0
    spacing: theme.space(12)
    SectionHeading { theme: root.theme; text: "Pinned"; hint: "Quick access, on every date."; Layout.fillWidth: true }
    GridLayout {
        Layout.fillWidth: true
        columns: width >= root.theme.space(600) ? 2 : 1
        columnSpacing: root.theme.space(12); rowSpacing: root.theme.space(8)
        uniformCellWidths: true
        Repeater {
            model: root.visible ? root.entries.slice(root.page * 6, (root.page + 1) * 6) : []
            Rectangle {
                id: pinnedCard
                required property var modelData
                Layout.fillWidth: true; Layout.minimumWidth: 0
                implicitHeight: actions.implicitHeight + root.theme.space(8)
                color: root.theme.surface; radius: root.theme.radius
                RowLayout {
                    id: actions
                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: root.theme.space(4)
                    spacing: root.theme.space(4)
                    DButton {
                        id: titleButton
                        theme: root.theme; quiet: true
                        objectName: "pinnedOpen-" + pinnedCard.modelData.id
                        Layout.fillWidth: true; Layout.minimumWidth: 0
                        implicitWidth: root.theme.space(150)
                        implicitHeight: Math.max(root.theme.space(44), labels.implicitHeight + topPadding + bottomPadding)
                        Accessible.name: pinnedCard.modelData.title + ", pinned activity, open details"
                        contentItem: Column {
                            id: labels; spacing: root.theme.space(4)
                            DText { theme: root.theme; text: pinnedCard.modelData.title; width: parent.width; maximumLineCount: 2; elide: Text.ElideRight }
                            DText { theme: root.theme; text: "Done · still pinned"; visible: pinnedCard.modelData.status === "done"; width: parent.width; font.pixelSize: root.theme.small; color: root.theme.secondary }
                        }
                        onClicked: root.workspace.selectActivity(pinnedCard.modelData.id)
                    }
                    DButton {
                        theme: root.theme; quiet: true; text: "Log"
                        objectName: "pinnedLog-" + pinnedCard.modelData.id
                        Accessible.name: "Log " + pinnedCard.modelData.title
                        onClicked: root.workspace.openComposer("log", pinnedCard.modelData.id)
                    }
                }
            }
        }
    }
    RowLayout {
        visible: root.pageCount > 1; Layout.fillWidth: true
        DButton { theme: root.theme; text: "Previous"; objectName: "pinnedPrevious"; quiet: true; enabled: root.page > 0; onClicked: root.page-- }
        DText { theme: root.theme; text: (root.page + 1) + " / " + root.pageCount; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; color: root.theme.secondary; font.pixelSize: root.theme.small }
        DButton { theme: root.theme; text: "More"; objectName: "pinnedNext"; quiet: true; enabled: root.page + 1 < root.pageCount; onClicked: root.page++ }
    }
}
