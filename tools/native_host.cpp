// Development-only Qt host. Requests stay on stdin, never in command arguments.
#include <QCoreApplication>
#include <QDir>
#include <QDebug>
#include <QFile>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QProcess>
#include <QQmlApplicationEngine>
#include <QTimer>
#include <QSet>
#include <QVariant>
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

class Transport final : public QObject {
    Q_OBJECT

public:
    Transport(QString python, QStringList arguments, QString profile, QObject *parent = nullptr)
        : QObject(parent), python_(std::move(python)), arguments_(std::move(arguments)),
          profile_(std::move(profile)), database_(profile_ + QStringLiteral("/daylog.sqlite3")) {
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
            failure_ = QStringLiteral("The storage helper timed out; the save outcome is unknown. Retry the same request.");
            process->kill();
        });
        connect(process, &QProcess::started, this, [this, process, payload = jsonLine.toUtf8()] {
            if (stopping_) {
                process->kill();
                return;
            }
            if (process->write(payload) != payload.size() || process->write("\n", 1) != 1) {
                failure_ = QStringLiteral("Could not send the request to the storage helper.");
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
                complete(process, {}, QStringLiteral("The storage helper could not start."));
            } else if (failure_.isEmpty()) {
                failure_ = QStringLiteral("The storage helper failed; the save outcome may be unknown.");
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
                complete(process, {}, QStringLiteral("The storage helper exited unsuccessfully; the save outcome may be unknown."));
                return;
            }
            const QByteArray response = output_.trimmed();
            QJsonParseError error;
            const auto document = QJsonDocument::fromJson(response, &error);
            if (response.isEmpty() || response.contains('\n') || error.error != QJsonParseError::NoError || !document.isObject()) {
                complete(process, {}, QStringLiteral("The storage helper returned a missing or malformed response."));
                return;
            }
            complete(process, QString::fromUtf8(response), {});
        });
        timeout->start(15000);
        process->start(python_, arguments_);
        return true;
    }

    void shutdown() {
        stopping_ = true;
        if (!process_) {
            emit stopped();
            return;
        }
        failure_ = QStringLiteral("The storage request was interrupted by application shutdown; its outcome may be unknown.");
        process_->kill();
    }

signals:
    void finished(const QString &response, const QString &transportError);
    void stopped();
    void dataChanged();
    void themeChanged(const QVariantMap &snapshot);

private:
    void watchDatabase() {
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
    QFileSystemWatcher watcher_{this};
    QTimer notify_{this};
    bool directoryWatched_ = false;
    bool databaseWatched_ = false;
    QProcess *process_ = nullptr;
    QByteArray output_;
    QString failure_;
    bool stopping_ = false;
};

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Daymark native development host"));
    app.setQuitOnLastWindowClosed(false);
    const auto arguments = app.arguments();
    const auto usage = "Usage: native_host QML_FILE PYTHON HELPER PROFILE [--read-only]\n"
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
    QString themeScript;
    QString themeScale = QStringLiteral("1");
    QStringList themePaths;
    for (qsizetype i = 5; i < arguments.size(); ++i) {
        const auto &option = arguments.at(i);
        if (option == QStringLiteral("--read-only")) {
            readOnly = true;
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
    ThemeWatcher theme(arguments.at(2), themeScript, themeScale, themePaths);
    QObject::connect(&theme, &ThemeWatcher::changed, &transport, &Transport::themeChanged);
    QQmlApplicationEngine engine;
    int exitCode = 0;
    const auto stop = [&transport, &exitCode](int code) {
        exitCode = code;
        transport.shutdown();
    };
    // Keep the event loop alive until the child is reaped, including Qt.quit().
    QObject::disconnect(&engine, &QQmlEngine::quit, &app, nullptr);
    QObject::disconnect(&engine, &QQmlEngine::exit, &app, nullptr);
    QObject::connect(&engine, &QQmlEngine::quit, &app, [&stop] { stop(0); });
    QObject::connect(&engine, &QQmlEngine::exit, &app, stop);
    QObject::connect(&transport, &Transport::stopped, &app, [&exitCode] {
        QCoreApplication::exit(exitCode);
    }, Qt::QueuedConnection);
    engine.setInitialProperties({{QStringLiteral("transport"), QVariant::fromValue(static_cast<QObject *>(&transport))}});
    engine.load(QUrl::fromLocalFile(arguments.at(1)));
    if (engine.rootObjects().isEmpty())
        stop(1);
    return app.exec();
}

#include "native_host.moc"
