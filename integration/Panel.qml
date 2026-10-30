import QtQuick

// The manifest entry routes keyboard/service-only invocation to the same eager
// native panel as every bar entry; unloading this facade never destroys drafts.
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
    function close() { return service ? service.dismiss() : true; }
    onOpenedChanged: {
        if (!opened && shell && manifest) shell.hide(manifest.id);
    }
}
