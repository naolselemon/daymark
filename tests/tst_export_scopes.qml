import QtQuick
import QtTest
import "../prototype" as Daymark

TestCase {
    id: testCase
    name: "ExportScopes"
    width: 800
    height: 900
    when: windowShown
    property var dialog
    property var requests: []
    property var pendingAuthorization: null
    property bool failExport: false
    property int sequence: 0

    Daymark.Theme {
        id: fixtureTheme
        source: ({background: "#181818", foreground: "#eeeeee", accent: "#aaccaa", urgent: "#ffaaaa",
            radius: 8, family: "sans-serif", scale: 1,
            font: {title: 14, body: 12, heading: 18, display: 22, "display-large": 28},
            spacing: {"control-gap": 8, "panel-padding": 16, "control-padding-y": 8, "control-padding-x": 12, "control-height": 44},
            states: {normal: {fill: "#222222", border: "#777777", width: 1},
                "hover-cursor": {fill: "#333333", border: "#999999", width: 1},
                pressed: {fill: "#333333", border: "#999999", width: 1},
                selected: {fill: "#222222", border: "#555555", width: 1},
                focus: {fill: "#333333", border: "#aaccaa", width: 1}}})
    }
    QtObject {
        id: fixtureStore
        function newRequestId() { return "synthetic-export-" + (++testCase.sequence); }
        function exportRecords(format, path, scope, callback, requestId) {
            testCase.requests = testCase.requests.concat([{format: format, path: path, scope: scope, requestId: requestId}]);
            callback(!testCase.failExport, {path: path}, {message: "Synthetic export failure"});
        }
    }
    QtObject {
        id: fixtureWorkspace
        property bool diaryUnlocked: true
        property bool diaryAuthenticating: false
        function authorizeDiary(action) {
            diaryAuthenticating = true;
            testCase.pendingAuthorization = action;
        }
    }
    Component {
        id: dialogFactory
        Daymark.DataSafety { theme: fixtureTheme; store: fixtureStore; workspace: fixtureWorkspace }
    }
    function init() {
        requests = [];
        pendingAuthorization = null;
        failExport = false;
        fixtureWorkspace.diaryUnlocked = true;
        fixtureWorkspace.diaryAuthenticating = false;
        dialog = createTemporaryObject(dialogFactory, testCase);
        verify(dialog);
        dialog.begin();
        tryCompare(dialog, "opened", true);
    }
    function finishAuthorization(accepted) {
        const callback = pendingAuthorization;
        pendingAuthorization = null;
        fixtureWorkspace.diaryAuthenticating = false;
        if (accepted) callback();
    }
    function test_failed_export_keeps_scope_destination_and_retry_identity() {
        dialog.diaryExportPath = "/synthetic/diary.json";
        dialog.activitiesExportPath = "/synthetic/activities.json";
        failExport = true;
        dialog.exportFile("diary");
        finishAuthorization(true);
        compare(requests.length, 1);
        const requestId = requests[0].requestId;
        compare(dialog.pendingScope, "diary");
        dialog.exportFile("activities");
        compare(requests.length, 1);
        failExport = false;
        dialog.exportFile("diary");
        compare(requests.length, 1);
        finishAuthorization(true);
        compare(requests.length, 2);
        compare(requests[1].requestId, requestId);
        compare(requests[1].path, requests[0].path);
        compare(dialog.activitiesExportPath, "/synthetic/activities.json");
        compare(dialog.diaryExportPath, "");
    }
    function test_stale_authorization_cannot_export_changed_destination_or_closed_dialog() {
        dialog.diaryExportPath = "/synthetic/first.json";
        dialog.exportFile("diary");
        dialog.diaryExportPath = "/synthetic/second.json";
        finishAuthorization(true);
        compare(requests.length, 0);
        dialog.exportFile("diary");
        dialog.close();
        tryCompare(dialog, "opened", false);
        finishAuthorization(true);
        compare(requests.length, 0);
    }
}
