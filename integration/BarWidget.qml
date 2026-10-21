pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import qs.Commons as Commons
import qs.Ui as Ui

Ui.BarWidget {
    id: root
    // The trusted built-in bar grants lookup of this plugin's service only.
    // A service-less replacement bar shows unavailable, not a second journal.
    readonly property var barHost: bar
    readonly property var service: barHost && barHost.shell ? barHost.shell.serviceFor(moduleName) : null
    readonly property bool opened: service ? service.opened : false
    implicitWidth: vertical ? barSize : button.implicitWidth
    implicitHeight: vertical ? button.implicitHeight : barSize
    function open() { if (service) service.open(); }
    function close() { if (service) service.close(); }
    function togglePanel() { if (service) service.toggle(); }

    Ui.BarIconButton {
        id: button
        objectName: "daymarkLauncher"
        anchors.fill: parent
        bar: root.barHost
        // Match neighboring glyphs, without shrinking the native click target.
        opticalSize: fontSize
        active: root.opened || tooltipHovered || activeFocus
        activeColor: Commons.Color.accent
        activeFocusOnTab: interactive
        interactive: !!root.service
        dimmed: !root.service
        tooltipText: !root.service ? "Daymark service unavailable in this bar host"
            : !root.service.records.loaded
                ? (root.service.records.lastError ? "Daymark · unavailable" : "Daymark · loading")
                : root.service.records.legacyError ? "Daymark · older entries need attention"
                : root.opened ? "Hide Daymark" : "Open Daymark"
        Accessible.role: Accessible.Button
        Accessible.name: "Daymark"
        Accessible.description: tooltipText
        Accessible.onPressAction: if (button.interactive) button.triggerPress(Qt.LeftButton)
        Keys.onPressed: event => {
            if (button.interactive && (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                event.accepted = true;
                if (!event.isAutoRepeat) button.triggerPress(Qt.LeftButton);
            }
        }
        onPressed: mouseButton => { if (mouseButton === Qt.LeftButton) root.togglePanel(); }

        Rectangle {
            anchors.fill: parent
            anchors.margins: Commons.Style.spaceReal(2)
            visible: button.activeFocus
            color: "transparent"
            radius: Math.min(Commons.Style.cornerRadius, width / 2, height / 2)
            border.color: Commons.Style.focusBorderFor(button.foreground, button.activeColor, Commons.Color.urgent)
            border.width: Math.max(1, Commons.Style.focusBorderWidth)
        }
        iconComponent: Item {
            id: iconCanvas
            // One scalable path: notebook cover, spine and a page marker.
            Shape {
                anchors.centerIn: parent
                width: 24
                height: 24
                scale: Math.min(iconCanvas.width, iconCanvas.height) / 24
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: button.active ? button.activeColor : button.foreground
                    strokeWidth: 1.6
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathSvg {
                        path: "M7 3.5 H18.5 Q20 3.5 20 5 V19 Q20 20.5 18.5 20.5 H7 Q4 20.5 4 17.5 V6.5 Q4 3.5 7 3.5 Z M7.5 4 V20 M12 3.5 V11 L14.5 9 L17 11 V3.5"
                    }
                }
            }
        }
    }
}
