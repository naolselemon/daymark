pragma ComponentBehavior: Bound
import QtQuick
import "../prototype" as Daymark
import qs.Commons as Commons
import qs.Ui as Ui

Ui.BarWidget {
    id: root
    // The trusted built-in bar grants lookup of this plugin's service only.
    // A service-less replacement bar shows unavailable, not a second journal.
    readonly property var barHost: bar
    readonly property var service: barHost && barHost.shell ? barHost.shell.serviceFor(moduleName) : null
    readonly property bool opened: service ? service.opened : false
    readonly property bool popoutSwitchClosing: service ? service.panel.popoutSwitchClosing : false
    property alias anchorItem: button
    property bool componentReady: false
    property var registeredService: null
    function syncReadiness() {
        const next = componentReady ? service : null;
        if (registeredService === next) return;
        if (registeredService) registeredService.unregisterBarWidget(root);
        registeredService = next;
        if (registeredService) registeredService.registerBarWidget(root);
    }
    onServiceChanged: syncReadiness()
    Component.onCompleted: { componentReady = true; syncReadiness(); }
    Component.onDestruction: { componentReady = false; syncReadiness(); }
    implicitWidth: vertical ? barSize : button.implicitWidth
    implicitHeight: vertical ? button.implicitHeight : barSize
    function open() { if (service) service.open(root); }
    function close() { return service ? service.dismiss() : true; }
    function closeForPopoutSwitch() { if (service) service.panel.closeForPopoutSwitch(); }
    function togglePanel() { if (service) service.toggle(root); }

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
        iconComponent: Daymark.DaymarkMark {
            ink: button.active ? button.activeColor : button.foreground
            accent: button.active ? button.activeColor : button.foreground
        }
    }
}
