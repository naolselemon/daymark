import QtQuick

// Only helper acknowledgments change canonical settings. Navigation has its own
// coalesced queue so it cannot replace an explicit settings change or its retry.
Item {
    id: root
    objectName: "preferencesController"
    required property var store
    visible: false
    property bool loaded: false
    property bool busy: false
    property string error: ""
    property string openingPage: "Timer"
    property string lastPage: "Timer"
    property bool onlineQuotes: false
    property int diaryIdleMinutes: 0
    property bool automaticUpdates: false
    property var pendingChanges: ({})
    property string pendingPage: ""
    property var retryRequest: null

    function validValue(key, value) {
        if (key === "openingPage") return ["Timer", "Today", "last"].indexOf(value) >= 0;
        if (key === "lastPage") return ["Timer", "Today", "Plan", "History", "Diary", "Quotes"].indexOf(value) >= 0;
        if (key === "onlineQuotes" || key === "automaticUpdates") return typeof value === "boolean";
        if (key === "diaryIdleMinutes") return typeof value === "number" && [0, 1, 5, 15].indexOf(value) >= 0;
        return false;
    }
    function validResult(result) {
        if (!result || typeof result !== "object") return false;
        const keys = ["openingPage", "lastPage", "onlineQuotes", "diaryIdleMinutes", "automaticUpdates"];
        for (let i = 0; i < keys.length; ++i)
            if (!validValue(keys[i], result[keys[i]])) return false;
        return true;
    }
    function accept(result) {
        openingPage = result.openingPage;
        lastPage = result.lastPage;
        onlineQuotes = result.onlineQuotes;
        diaryIdleMinutes = result.diaryIdleMinutes;
        automaticUpdates = result.automaticUpdates;
        loaded = true;
    }
    function dispatch(op, args, requestId) {
        if (busy) return;
        busy = true;
        error = "";
        const id = requestId || store.newRequestId();
        store.request(op, args, function(ok, result, failure) {
            if (ok && !validResult(result)) {
                ok = false;
                failure = {message: "Settings returned an invalid response. No success was confirmed."};
            }
            if (ok) {
                accept(result);
                retryRequest = null;
            } else {
                retryRequest = {op: op, args: args, id: id};
                error = (failure && failure.message) || "Settings could not be read or saved.";
            }
            busy = false;
            if (ok) Qt.callLater(flush);
        }, id);
    }
    function refresh() {
        if (busy) return;
        if (retryRequest) retry();
        else dispatch("preferences_get", {});
    }
    function retry() {
        if (busy) return;
        if (retryRequest) dispatch(retryRequest.op, retryRequest.args, retryRequest.id);
        else refresh();
    }
    function setValue(key, value) {
        if (!loaded || error || !validValue(key, value)) return false;
        const changes = Object.assign({}, pendingChanges);
        changes[key] = value;
        pendingChanges = changes;
        flush();
        return true;
    }
    function rememberPage(page) {
        if (!validValue("lastPage", page)) return;
        pendingPage = page;
        pageSave.restart();
    }
    function flush() {
        if (!loaded || busy || error) return;
        if (Object.keys(pendingChanges).length) {
            const changes = pendingChanges;
            pendingChanges = ({});
            dispatch("preferences_set", {changes: changes});
        } else if (pendingPage && !pageSave.running) {
            const page = pendingPage;
            pendingPage = "";
            if (page !== lastPage) dispatch("preferences_set", {changes: {lastPage: page}});
        }
    }
    Timer {
        id: pageSave
        interval: 250
        onTriggered: root.flush()
    }
    Component.onCompleted: Qt.callLater(refresh)
}
