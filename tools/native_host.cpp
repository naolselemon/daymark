// Development-only Qt host. Requests stay on stdin, never in command arguments.
#include <QCoreApplication>
#include <QDir>
#include <QDebug>
#include <QElapsedTimer>
#include <QEvent>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QGuiApplication>
#include <QHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QProcess>
#include <QQmlApplicationEngine>
#include <QTimer>
#include <QSet>
#include <QVariant>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <utility>
#include <sys/stat.h>
#include <vector>

// Preview-only live token projection. All timers are event-triggered debounce
// or child deadlines; there is no idle refresh loop or resident helper.
class ThemeWatcher final : public QObject {
    Q_OBJECT

public:
    ThemeWatcher(QString python, QString script, QString scale, QStringList paths,
                 QObject *parent = nullptr)
        : QObject(parent), python_(std::move(python)), script_(std::move(script)),
          scale_(std::move(scale)), paths_(std::move(paths)), versions_(paths_.size()) {
        debounce_.setSingleShot(true);
        debounce_.setInterval(200);
        deadline_.setSingleShot(true);
        deadline_.setInterval(5000);
        connect(&debounce_, &QTimer::timeout, this, &ThemeWatcher::project);
        connect(&deadline_, &QTimer::timeout, this, [this] {
            failure_ = QStringLiteral("The theme projector timed out.");
            process_.kill();
        });
        connect(&watcher_, &QFileSystemWatcher::fileChanged, this, [this] {
            updateVersions();
            rearm();
            schedule();
        });
        connect(&watcher_, &QFileSystemWatcher::directoryChanged, this, [this] {
            const bool changed = updateVersions();
            rearm();
            if (changed)
                schedule();
        });
        connect(&process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart) {
                deadline_.stop();
                qWarning() << "Theme update retained the last valid snapshot: projector could not start.";
            }
        });
        connect(&process_, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
            deadline_.stop();
            const auto output = process_.readAllStandardOutput();
            const auto diagnostics = process_.readAllStandardError().trimmed();
            // An event arriving while Python read the files invalidates its
            // result. Project again once the observed change has settled.
            if (pending_) {
                debounce_.start();
                return;
            }
            QJsonParseError error;
            const auto document = QJsonDocument::fromJson(output, &error);
            if (code != 0 || status != QProcess::NormalExit
                || error.error != QJsonParseError::NoError || !document.isObject()) {
                qWarning().noquote() << "Theme update retained the last valid snapshot:"
                                    << (failure_.isEmpty() ? QString::fromUtf8(diagnostics) : failure_);
                return;
            }
            emit changed(document.object().toVariantMap());
        });
        if (!script_.isEmpty()) {
            updateVersions();
            rearm();
            // Close the gap between preview.py's initial snapshot and startup.
            schedule();
        }
    }

    ~ThemeWatcher() override {
        if (process_.state() != QProcess::NotRunning) {
            process_.kill();
            process_.waitForFinished(5000);
        }
    }

signals:
    void changed(const QVariantMap &snapshot);

private:
    bool updateVersions() {
        bool changed = false;
        for (qsizetype i = 0; i < paths_.size(); ++i) {
            struct stat next {};
            // Missing files have the all-zero version, so creation and
            // deletion are changes too. stat follows the current symlink.
            if (::stat(QFile::encodeName(paths_.at(i)).constData(), &next) != 0)
                next = {};
            const auto &old = versions_[i];
            changed |= old.st_dev != next.st_dev || old.st_ino != next.st_ino
                || old.st_size != next.st_size
                || old.st_mtim.tv_sec != next.st_mtim.tv_sec
                || old.st_mtim.tv_nsec != next.st_mtim.tv_nsec
                || old.st_ctim.tv_sec != next.st_ctim.tv_sec
                || old.st_ctim.tv_nsec != next.st_ctim.tv_nsec;
            versions_[i] = next;
        }
        return changed;
    }

    void rearm() {
        QSet<QString> paths;
        const auto addAncestors = [&paths](QString path) {
            while (!path.isEmpty()) {
                if (QFileInfo::exists(path))
                    paths.insert(path);
                const QString parent = QFileInfo(path).absolutePath();
                if (parent == path)
                    break;
                path = parent;
            }
        };
        for (const auto &path : paths_) {
            addAncestors(path);
            addAncestors(QFileInfo(path).canonicalFilePath());
        }
        // Replacing a directory can leave a lexical path attached to the old
        // inode. Reattach all paths, including resolved targets and ancestors;
        // a surviving ancestor notices recreation even after an absent parent.
        const auto files = watcher_.files();
        const auto directories = watcher_.directories();
        if (!files.isEmpty())
            watcher_.removePaths(files);
        if (!directories.isEmpty())
            watcher_.removePaths(directories);
        const auto failed = watcher_.addPaths(paths.values());
        if (!failed.isEmpty())
            qWarning() << "Could not watch theme paths:" << failed;
    }

    void schedule() {
        pending_ = true;
        debounce_.start();
    }

    void project() {
        if (process_.state() != QProcess::NotRunning)
            return;
        pending_ = false;
        failure_.clear();
        deadline_.start();
        process_.start(python_, {script_, QStringLiteral("--snapshot"),
                                QStringLiteral("--theme"), QStringLiteral("current"),
                                QStringLiteral("--scale"), scale_});
    }

    QString python_;
    QString script_;
    QString scale_;
    QStringList paths_;
    std::vector<struct stat> versions_;
    QFileSystemWatcher watcher_{this};
    QTimer debounce_{this};
    QTimer deadline_{this};
    QProcess process_{this};
    QString failure_;
    bool pending_ = false;
};

// Development-host input only. The installed plugin uses the compositor's
// IdleMonitor; this adapter neither watches other apps nor records keys.
class PreviewIdleMonitor final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(double timeout READ timeout WRITE setTimeout NOTIFY timeoutChanged)
    Q_PROPERTY(bool isIdle READ isIdle NOTIFY isIdleChanged)
public:
    explicit PreviewIdleMonitor(QObject *parent = nullptr) : QObject(parent) {
        QCoreApplication::instance()->installEventFilter(this);
        connect(&check_, &QTimer::timeout, this, [this] {
            if (enabled_ && sinceInput_.elapsed() >= qRound64(timeout_ * 1000))
                setIdle(true);
        });
    }
    bool enabled() const { return enabled_; }
    double timeout() const { return timeout_; }
    bool isIdle() const { return idle_; }
    void setEnabled(bool enabled) {
        if (enabled_ == enabled) return;
        enabled_ = enabled;
        reset();
        emit enabledChanged();
    }
    void setTimeout(double seconds) {
        if (!std::isfinite(seconds)) return;
        seconds = std::clamp(seconds, 0.0, 900.0);
        if (timeout_ == seconds) return;
        timeout_ = seconds;
        reset();
        emit timeoutChanged();
    }
signals:
    void enabledChanged();
    void timeoutChanged();
    void isIdleChanged();
protected:
    bool eventFilter(QObject *watched, QEvent *event) override {
        if (enabled_) {
            switch (event->type()) {
            case QEvent::KeyPress:
            case QEvent::KeyRelease:
            case QEvent::InputMethod:
            case QEvent::MouseMove:
            case QEvent::MouseButtonPress:
            case QEvent::MouseButtonRelease:
            case QEvent::MouseButtonDblClick:
            case QEvent::Wheel:
            case QEvent::TouchBegin:
            case QEvent::TouchUpdate:
            case QEvent::TouchEnd:
            case QEvent::TabletMove:
            case QEvent::TabletPress:
            case QEvent::TabletRelease:
                sinceInput_.restart();
                setIdle(false);
                break;
            default:
                break;
            }
        }
        return QObject::eventFilter(watched, event);
    }
private:
    void setIdle(bool idle) {
        if (idle_ == idle) return;
        idle_ = idle;
        emit isIdleChanged();
    }
    void reset() {
        check_.stop();
        setIdle(false);
        if (!enabled_) return;
        sinceInput_.restart();
        check_.start(std::clamp(qRound(timeout_ * 1000), 1, 1000));
    }
    QTimer check_{this};
    QElapsedTimer sinceInput_;
    bool enabled_ = false;
    bool idle_ = false;
    double timeout_ = 0;
};

class Transport final : public QObject {
    Q_OBJECT

public:
    Transport(QString python, QStringList arguments, QString profile, int timeoutMs = 15000,
              bool watchProfile = true, QString helperName = QStringLiteral("storage"), QObject *parent = nullptr)
        : QObject(parent), python_(std::move(python)), arguments_(std::move(arguments)),
          profile_(std::move(profile)), database_(profile_ + QStringLiteral("/daylog.sqlite3")),
          timeoutMs_(timeoutMs), watchProfile_(watchProfile), helperName_(std::move(helperName)) {
        notify_.setSingleShot(true);
        notify_.setInterval(100);
        connect(&notify_, &QTimer::timeout, this, &Transport::dataChanged);
        connect(&watcher_, &QFileSystemWatcher::directoryChanged, this, [this] {
            directoryWatched_ = watcher_.directories().contains(profile_);
            watchDatabase();
            notify_.start();
        });
        connect(&watcher_, &QFileSystemWatcher::fileChanged, this, [this] {
            databaseWatched_ = watcher_.files().contains(database_);
            watchDatabase();
            notify_.start();
        });
        watchDatabase();
    }

    Q_INVOKABLE bool send(const QString &jsonLine) {
        if (process_ || stopping_)
            return false;
        auto *process = new QProcess(this);
        process_ = process;
        process->setStandardErrorFile(QProcess::nullDevice());
        auto *timeout = new QTimer(process);
        timeout->setSingleShot(true);
        connect(timeout, &QTimer::timeout, this, [this, process] {
            failure_ = QStringLiteral("The ") + helperName_ + QStringLiteral(" helper timed out; the operation outcome is unknown.");
            process->kill();
        });
        connect(process, &QProcess::started, this, [this, process, payload = jsonLine.toUtf8()] {
            if (stopping_ || !failure_.isEmpty()) {
                process->kill();
                return;
            }
            if (process->write(payload) != payload.size() || process->write("\n", 1) != 1) {
                failure_ = QStringLiteral("Could not send the request to the ") + helperName_ + QStringLiteral(" helper.");
                process->kill();
                return;
            }
            process->closeWriteChannel();
        });
        connect(process, &QProcess::readyReadStandardOutput, this, [this, process] {
            output_.append(process->readAllStandardOutput());
        });
        connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart) {
                complete(process, {}, QStringLiteral("The ") + helperName_ + QStringLiteral(" helper could not start."));
            } else if (failure_.isEmpty()) {
                failure_ = QStringLiteral("The ") + helperName_ + QStringLiteral(" helper failed; the operation outcome may be unknown.");
                process->kill();
            }
        });
        connect(process, &QProcess::finished, this, [this, process](int exitCode, QProcess::ExitStatus status) {
            output_.append(process->readAllStandardOutput());
            if (!failure_.isEmpty()) {
                complete(process, {}, failure_);
                return;
            }
            if (status != QProcess::NormalExit || exitCode != 0) {
                complete(process, {}, QStringLiteral("The ") + helperName_ + QStringLiteral(" helper exited unsuccessfully; the operation outcome may be unknown."));
                return;
            }
            const QByteArray response = output_.trimmed();
            QJsonParseError error;
            const auto document = QJsonDocument::fromJson(response, &error);
            if (response.isEmpty() || response.contains('\n') || error.error != QJsonParseError::NoError || !document.isObject()) {
                complete(process, {}, QStringLiteral("The ") + helperName_ + QStringLiteral(" helper returned a missing or malformed response."));
                return;
            }
            complete(process, QString::fromUtf8(response), {});
        });
        timeout->start(timeoutMs_);
        process->start(python_, arguments_);
        return true;
    }

    Q_INVOKABLE void cancel() {
        if (!process_) return;
        failure_ = QStringLiteral("The ") + helperName_ + QStringLiteral(" request was cancelled; checking saved state.");
        process_->kill();
    }

    void shutdown() {
        stopping_ = true;
        if (!process_) {
            emit stopped();
            return;
        }
        failure_ = QStringLiteral("The ") + helperName_ + QStringLiteral(" request was interrupted; its outcome may be unknown.");
        process_->kill();
    }

signals:
    void finished(const QString &response, const QString &transportError);
    void stopped();
    void dataChanged();
    void themeChanged(const QVariantMap &snapshot);

private:
    void watchDatabase() {
        if (!watchProfile_) return;
        // Directory events cover initial creation and journal commits; re-arm
        // the file watch after replacement. No idle subprocess or polling.
        if (!directoryWatched_ && QFileInfo::exists(profile_))
            directoryWatched_ = watcher_.addPath(profile_);
        if (!databaseWatched_ && QFileInfo::exists(database_))
            databaseWatched_ = watcher_.addPath(database_);
    }

    void complete(QProcess *process, QString response, QString error) {
        if (process_ != process)
            return;
        process->disconnect(this);
        process->findChild<QTimer *>()->stop();
        // No active child is deleted: finished/failed-start are the only callers.
        process->deleteLater();
        process_ = nullptr;
        output_.clear();
        failure_.clear();
        watchDatabase();
        emit finished(response, error);
        if (stopping_)
            emit stopped();
    }

    QString python_;
    QStringList arguments_;
    QString profile_;
    QString database_;
    const int timeoutMs_;
    const bool watchProfile_;
    const QString helperName_;
    QFileSystemWatcher watcher_{this};
    QTimer notify_{this};
    bool directoryWatched_ = false;
    bool databaseWatched_ = false;
    QProcess *process_ = nullptr;
    QByteArray output_;
    QString failure_;
    bool stopping_ = false;
};

// Preview notifications are opt-in: ordinary screenshots must not notify the desktop.
class NotificationTransport final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled CONSTANT)
    Q_PROPERTY(QString unavailableReason READ unavailableReason CONSTANT)
public:
    explicit NotificationTransport(bool enabled, QObject *parent = nullptr)
        : QObject(parent), enabled_(enabled) {}
    ~NotificationTransport() override {
        for (auto *process : std::as_const(requests_)) {
            process->disconnect(this);
            process->kill();
            process->waitForFinished(3000);
        }
    }
    bool enabled() const { return enabled_; }
    QString unavailableReason() const {
        return enabled_ ? QString() : QStringLiteral(
            "Desktop notifications are disabled in this preview. Use --desktop-notifications only for an authorized synthetic test.");
    }
    Q_INVOKABLE bool execute(const QString &token, const QStringList &arguments, int timeoutMs) {
        if (!enabled_ || stopping_ || arguments.isEmpty() || requests_.contains(token))
            return false;
        auto *process = new QProcess(this);
        requests_.insert(token, process);
        process->setStandardErrorFile(QProcess::nullDevice());
        auto *deadline = new QTimer(process);
        deadline->setSingleShot(true);
        connect(deadline, &QTimer::timeout, this, [process] {
            process->setProperty("notificationFailure", QStringLiteral("The desktop notification request timed out."));
            process->kill();
        });
        connect(process, &QProcess::errorOccurred, this, [this, process, token](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart)
                complete(token, process, {}, QStringLiteral("The desktop notification command could not start."));
        });
        connect(process, &QProcess::finished, this, [this, process, token](int code, QProcess::ExitStatus status) {
            QString failure = process->property("notificationFailure").toString();
            if (failure.isEmpty() && (code != 0 || status != QProcess::NormalExit))
                failure = QStringLiteral("The desktop notification command failed.");
            complete(token, process, QString::fromUtf8(process->readAllStandardOutput()), failure);
        });
        if (timeoutMs > 0)
            deadline->start(timeoutMs);
        process->start(arguments.first(), arguments.sliced(1));
        return true;
    }
    void shutdown() {
        stopping_ = true;
        if (requests_.isEmpty()) {
            emit stopped();
            return;
        }
        for (auto *process : std::as_const(requests_))
            process->kill();
    }
signals:
    void finished(const QString &token, const QString &output, const QString &failure);
    void stopped();
private:
    void complete(const QString &token, QProcess *process, const QString &output, const QString &failure) {
        if (requests_.value(token) != process)
            return;
        requests_.remove(token);
        process->disconnect(this);
        process->findChild<QTimer *>()->stop();
        process->deleteLater();
        if (!stopping_)
            emit finished(token, output, failure);
        else if (requests_.isEmpty())
            emit stopped();
    }
    const bool enabled_;
    bool stopping_ = false;
    QHash<QString, QProcess *> requests_;
};

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Daymark native development host"));
    app.setQuitOnLastWindowClosed(false);
    const auto arguments = app.arguments();
    const auto usage = "Usage: native_host QML_FILE PYTHON HELPER PROFILE [--read-only] [--desktop-notifications]\n"
                       "  [--theme-script PATH --theme-scale NUMBER --theme-watch PATH ...]\n"
                       "All paths must be absolute. PROFILE must be explicitly selected outside the source tree.\n";
    if (arguments.size() == 2 && arguments.at(1) == QStringLiteral("--help")) {
        std::fputs(usage, stdout);
        return 0;
    }
    if (arguments.size() < 5) {
        std::fputs(usage, stderr);
        return 2;
    }
    bool readOnly = false;
    bool desktopNotifications = false;
    QString themeScript;
    QString themeScale = QStringLiteral("1");
    QStringList themePaths;
    for (qsizetype i = 5; i < arguments.size(); ++i) {
        const auto &option = arguments.at(i);
        if (option == QStringLiteral("--read-only")) {
            readOnly = true;
        } else if (option == QStringLiteral("--desktop-notifications")) {
            desktopNotifications = true;
        } else if ((option == QStringLiteral("--theme-script")
                    || option == QStringLiteral("--theme-scale")
                    || option == QStringLiteral("--theme-watch")) && i + 1 < arguments.size()) {
            const auto &value = arguments.at(++i);
            if (option == QStringLiteral("--theme-script"))
                themeScript = value;
            else if (option == QStringLiteral("--theme-scale"))
                themeScale = value;
            else
                themePaths.append(value);
        } else {
            std::fputs(usage, stderr);
            return 2;
        }
    }
    if (themeScript.isEmpty() != themePaths.isEmpty()
        || (!themeScript.isEmpty()
            && (!QDir::isAbsolutePath(themeScript) || !QFileInfo(themeScript).isFile()))) {
        std::fputs("Live themes require an absolute projector path and watched paths.\n", stderr);
        return 2;
    }
    for (const auto &path : themePaths) {
        if (!QDir::isAbsolutePath(path)) {
            std::fputs("Theme watch paths must be absolute.\n", stderr);
            return 2;
        }
    }
    for (int i = 1; i <= 4; ++i) {
        if (!QDir::isAbsolutePath(arguments.at(i))) {
            std::fputs("Native host paths must be absolute.\n", stderr);
            return 2;
        }
    }
    if (!QFileInfo(arguments.at(1)).isFile() || !QFileInfo(arguments.at(2)).isExecutable()
        || !QFileInfo(arguments.at(3)).isFile()) {
        std::fputs("A native host input file or Python executable is unavailable.\n", stderr);
        return 2;
    }
    QStringList helperArguments{arguments.at(3), QStringLiteral("--profile"), arguments.at(4)};
    if (readOnly)
        helperArguments.append(QStringLiteral("--read-only"));
    Transport transport(arguments.at(2), helperArguments, arguments.at(4));
    const QString updateHelper = QFileInfo(arguments.at(3)).dir().filePath(QStringLiteral("updater.py"));
    if (!QFileInfo(updateHelper).isFile()) {
        std::fputs("The update helper is unavailable beside the journal helper.\n", stderr);
        return 2;
    }
    QStringList updateArguments{updateHelper, QStringLiteral("--profile"), arguments.at(4)};
    if (readOnly)
        updateArguments.append(QStringLiteral("--read-only"));
    Transport updates(arguments.at(2), updateArguments, arguments.at(4), 300000, false, QStringLiteral("update"));
    const QString calendarHelper = QFileInfo(arguments.at(3)).dir().filePath(QStringLiteral("calendar_feed.py"));
    QStringList calendarArguments{calendarHelper, QStringLiteral("--profile"), arguments.at(4)};
    if (readOnly)
        calendarArguments.append(QStringLiteral("--read-only"));
    Transport calendar(arguments.at(2), calendarArguments, arguments.at(4), 20000, false, QStringLiteral("calendar"));
    PreviewIdleMonitor idleMonitor;
    NotificationTransport notifications(desktopNotifications);
    ThemeWatcher theme(arguments.at(2), themeScript, themeScale, themePaths);
    QObject::connect(&theme, &ThemeWatcher::changed, &transport, &Transport::themeChanged);
    QQmlApplicationEngine engine;
    int exitCode = 0;
    bool stopping = false;
    int stoppedCount = 0;
    const auto stop = [&transport, &updates, &calendar, &notifications, &exitCode, &stopping](int code) {
        if (stopping) return;
        stopping = true;
        exitCode = code;
        transport.shutdown();
        updates.shutdown();
        calendar.shutdown();
        notifications.shutdown();
    };
    // Keep the event loop alive until the child is reaped, including Qt.quit().
    QObject::disconnect(&engine, &QQmlEngine::quit, &app, nullptr);
    QObject::disconnect(&engine, &QQmlEngine::exit, &app, nullptr);
    QObject::connect(&engine, &QQmlEngine::quit, &app, [&stop] { stop(0); });
    QObject::connect(&engine, &QQmlEngine::exit, &app, stop);
    const auto stopped = [&exitCode, &stoppedCount] {
        if (++stoppedCount == 4) QCoreApplication::exit(exitCode);
    };
    QObject::connect(&transport, &Transport::stopped, &app, stopped, Qt::QueuedConnection);
    QObject::connect(&updates, &Transport::stopped, &app, stopped, Qt::QueuedConnection);
    QObject::connect(&calendar, &Transport::stopped, &app, stopped, Qt::QueuedConnection);
    QObject::connect(&notifications, &NotificationTransport::stopped, &app, stopped, Qt::QueuedConnection);
    engine.setInitialProperties({
        {QStringLiteral("transport"), QVariant::fromValue(static_cast<QObject *>(&transport))},
        {QStringLiteral("updateTransport"), QVariant::fromValue(static_cast<QObject *>(&updates))},
        {QStringLiteral("calendarTransport"), QVariant::fromValue(static_cast<QObject *>(&calendar))},
        {QStringLiteral("notificationTransport"), QVariant::fromValue(static_cast<QObject *>(&notifications))},
        {QStringLiteral("idleMonitor"), QVariant::fromValue(static_cast<QObject *>(&idleMonitor))}});
    engine.load(QUrl::fromLocalFile(arguments.at(1)));
    if (engine.rootObjects().isEmpty())
        stop(1);
    return app.exec();
}

#include "native_host.moc"
