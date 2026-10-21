import QtQuick

// The host injects the same service used by every bar instance. This routing
// object never owns records; its window survives loader recreation.
QtObject {
    id: root
    property var shell: null
    property var manifest: null
    property var service: null
    readonly property bool opened: service ? service.opened : false
    function open(payloadJson) {
        if (!service) return false;
        service.open();
        return true;
    }
    function close() { return service ? service.close() : true; }
    onOpenedChanged: {
        if (!opened && shell && manifest) shell.hide(manifest.id);
    }
}
