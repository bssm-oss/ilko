#include "MainWindow.h"

#include <QApplication>
#include <QAction>
#include <QStatusBar>
#include <QFileDialog>
#include <QMessageBox>
#include <QHBoxLayout>
#include <QFormLayout>
#include <QSlider>
#include <QComboBox>
#include <QRegularExpression>
#include <QFileInfo>

static QString profilesPath() {
    return QDir::homePath() + "/.ilko/profiles.json";
}

// Reads the currently-active profile ID from daemon's JSON
static QString readCurrentProfileId()
{
    QFile f(QDir::homePath() + "/.ilko/current_wallpaper.json");
    if (!f.open(QIODevice::ReadOnly)) return {};
    auto doc = QJsonDocument::fromJson(f.readAll());
    f.close();
    return doc.object().value("profileId").toString();
}

static const QStringList kVideoExts = {"mp4", "webm", "mov", "avi", "mkv", "m4v", "flv", "wmv"};

// Returns a scaled thumbnail for a wallpaper path.
// Videos: extracts one frame via ffmpeg, cached in ~/.ilko/thumbnails/<id>.jpg
// Images: loads directly from file
static QPixmap wallpaperThumbnail(const QString &wallpaperPath, const QString &profileId, const QSize &size)
{
    if (wallpaperPath.isEmpty()) return {};

    QFileInfo fi(wallpaperPath);
    if (!fi.exists()) return {};

    QString sourceForPixmap = wallpaperPath;

    if (kVideoExts.contains(fi.suffix().toLower())) {
        QString thumbDir = QDir::homePath() + "/.ilko/thumbnails";
        QString thumbPath = thumbDir + "/" + profileId + ".jpg";

        if (!QFile::exists(thumbPath)) {
            QDir().mkpath(thumbDir);
            QProcess p;
            // Seek to 1 second before opening to avoid black frames
            p.start("ffmpeg", {"-ss", "1", "-i", wallpaperPath,
                               "-vframes", "1", "-q:v", "3", "-y", thumbPath});
            p.waitForFinished(8000);
        }

        if (!QFile::exists(thumbPath)) return {};
        sourceForPixmap = thumbPath;
    }

    QPixmap px(sourceForPixmap);
    if (px.isNull()) return {};
    return px.scaled(size, Qt::KeepAspectRatioByExpanding, Qt::SmoothTransformation)
             .copy(0, 0, size.width(), size.height());
}

QList<ProfileData> ProfileData::loadAll() {
    QList<ProfileData> result;
    QFile file(profilesPath());
    if (!file.open(QIODevice::ReadOnly)) return result;
    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    file.close();
    if (!doc.isObject()) return result;
    QJsonArray arr = doc.object()["profiles"].toArray();
    for (auto v : arr) {
        auto p = v.toObject();
        ProfileData d;
        d.id = p["id"].toString();
        d.name = p["name"].toString();
        d.gatewayMac = p["gatewayMac"].toString();
        d.wallpaperPath = p["wallpaperPath"].toString();
        d.isDefault = p["isDefault"].toBool(false);
        d.targetFps = p["targetFps"].toInt(30);
        d.batteryPause = p["batteryPause"].toBool(true);
        result.append(d);
    }
    return result;
}

void ProfileData::saveAll(const QList<ProfileData>& profiles) {
    QDir().mkpath(QDir::homePath() + "/.ilko");
    QJsonArray arr;
    for (const auto& p : profiles) {
        QJsonObject o;
        o["id"] = p.id; o["name"] = p.name; o["gatewayMac"] = p.gatewayMac;
        o["wallpaperPath"] = p.wallpaperPath; o["isDefault"] = p.isDefault; o["targetFps"] = p.targetFps; o["batteryPause"] = p.batteryPause;
        arr.append(o);
    }
    QFile file(profilesPath());
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(QJsonObject{{"profiles", arr}}).toJson());
    }
}

void ProfileData::ensureDefaultExists() {
    auto profiles = loadAll();
    for (const auto& p : profiles) if (p.isDefault) return;
    ProfileData d;
    d.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    d.name = "기본 (일코)";
    d.isDefault = true;
    profiles.prepend(d);
    saveAll(profiles);
}

// ── MainWindow ─────────────────────────────────────────────

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
{
    ProfileData::ensureDefaultExists();
    setupUi();
    setupTrayIcon();
    setWindowTitle("ILKO");
    setWindowIcon(QIcon(":/ilko.png"));
    resize(900, 650);
    setMinimumSize(600, 250);
}

MainWindow::~MainWindow() = default;

void MainWindow::setupUi()
{
    auto central = new QWidget(this);
    setCentralWidget(central);
    auto layout = new QVBoxLayout(central);
    layout->setContentsMargins(16, 12, 16, 12);

    // Toolbar: 새로고침 | 프로필, 설정
    auto toolbar = new QToolBar(this);
    toolbar->setMovable(false);
    addToolBar(toolbar);
    auto reloadAct = toolbar->addAction("새로고침");
    toolbar->addSeparator();
    auto profilesAct = toolbar->addAction("프로필");
    auto settingsAct = toolbar->addAction("설정");

    // Profiles grid 
    m_videoGrid = new QListWidget(this);
    m_videoGrid->setViewMode(QListWidget::IconMode);
    m_videoGrid->setIconSize(QSize(200, 120));
    m_videoGrid->setGridSize(QSize(204, 140));
    m_videoGrid->setSpacing(10);
    m_videoGrid->setMovement(QListWidget::Static);
    m_videoGrid->setResizeMode(QListWidget::Adjust);
    m_videoGrid->setSelectionMode(QListWidget::SingleSelection);
    layout->addWidget(m_videoGrid, 1);

    connect(reloadAct, &QAction::triggered, this, &MainWindow::updateVideoGrid);
    connect(profilesAct, &QAction::triggered, this, &MainWindow::showProfilesDialog);
    connect(settingsAct, &QAction::triggered, this, &MainWindow::showSettingsDialog);
    connect(m_videoGrid, &QListWidget::itemDoubleClicked, this, &MainWindow::onVideoDoubleClicked);

    updateVideoGrid();
    statusBar()->showMessage("준비");
}

void MainWindow::setupTrayIcon()
{
    if (!QSystemTrayIcon::isSystemTrayAvailable()) return;
    m_trayIcon = new QSystemTrayIcon(this);
    m_trayIcon->setIcon(QIcon::fromTheme("video-television"));

    m_trayMenu = new QMenu(this);

    // Current profile indicator (disabled — info only)
    m_currentProfileAction = m_trayMenu->addAction("현재 프로필: -");
    m_currentProfileAction->setEnabled(false);
    m_trayMenu->addSeparator();

    m_trayMenu->addAction("열기", this, [this]() { show(); activateWindow(); raise(); });
    m_trayMenu->addSeparator();
    m_trayMenu->addAction("종료", this, &MainWindow::onQuit);

    m_trayIcon->setContextMenu(m_trayMenu);
    connect(m_trayIcon, &QSystemTrayIcon::activated, this, &MainWindow::onTrayIconActivated);
    // Refresh current profile name each time the menu is opened
    connect(m_trayMenu, &QMenu::aboutToShow, this, &MainWindow::refreshTrayMenu);
    m_trayIcon->show();
}

void MainWindow::refreshTrayMenu()
{
    if (!m_currentProfileAction) return;
    const QString currentId = readCurrentProfileId();
    const auto profiles = ProfileData::loadAll();
    for (const auto &p : profiles) {
        if (p.id == currentId) {
            m_currentProfileAction->setText(QString("현재 프로필: %1").arg(p.name));
            return;
        }
    }
    m_currentProfileAction->setText("현재 프로필: -");
}

void MainWindow::updateVideoGrid()
{
    m_videoGrid->clear();

    auto profiles = ProfileData::loadAll();
    const QString currentId = readCurrentProfileId();
    QString currentName;

    for (const auto& profile : profiles) {
        bool active = (profile.id == currentId);

        QString displayName = profile.isDefault
            ? profile.name
            : QString("%1\n%2").arg(profile.name).arg(profile.gatewayMac);

        auto item = new QListWidgetItem(displayName, m_videoGrid);
        item->setData(Qt::UserRole, profile.id);

        QPixmap thumb = wallpaperThumbnail(profile.wallpaperPath, profile.id, QSize(200, 120));
        if (!thumb.isNull())
            item->setIcon(QIcon(thumb));
        else
            item->setIcon(QIcon::fromTheme("image-missing"));

        if (active) {
            QFont f = item->font();
            f.setBold(true);
            item->setFont(f);
            // Blue background tint to mark the active profile
            item->setBackground(QColor(0, 120, 215, 40));
            currentName = profile.name;
        }
    }

    if (!currentName.isEmpty())
        statusBar()->showMessage(QString("현재 프로필: %1 | 총 %2개").arg(currentName).arg(profiles.size()));
    else
        statusBar()->showMessage(QString("%1개 프로필").arg(profiles.size()));
}

void MainWindow::onVideoDoubleClicked(QListWidgetItem *item)
{
    QString profileId = item->data(Qt::UserRole).toString();
    auto profiles = ProfileData::loadAll();
    
    for (const auto& p : profiles) {
        if (p.id == profileId) {
            ProfileEditDialog dlg(p, false, this);
            if (dlg.exec() == QDialog::Accepted) {
                auto updated = dlg.getProfile();
                for (int i = 0; i < profiles.size(); ++i) {
                    if (profiles[i].id == profileId) {
                        profiles[i] = updated;
                        break;
                    }
                }
                ProfileData::saveAll(profiles);
                updateVideoGrid();
                emit profileSaved();
            }
            return;
        }
    }
}

void MainWindow::showProfilesDialog() {
    ProfilesDialog(this).exec();
    updateVideoGrid();  // sync after add/edit/delete
    emit profileSaved();
}
void MainWindow::showSettingsDialog() { SettingsDialog(this).exec(); }

void MainWindow::onTrayIconActivated(QSystemTrayIcon::ActivationReason r) {
    if (r == QSystemTrayIcon::Trigger || r == QSystemTrayIcon::DoubleClick)
        { show(); activateWindow(); raise(); }
}

void MainWindow::onQuit() { QCoreApplication::quit(); }

// ── ProfilesDialog (macOS ProfilesView 와 동일) ─────────────

ProfilesDialog::ProfilesDialog(QWidget *parent) : QDialog(parent)
{
    setWindowTitle("프로필 관리");
    resize(500, 400);

    auto layout = new QVBoxLayout(this);

    // Header: 제목 + 추가 버튼
    auto header = new QHBoxLayout();
    header->addWidget(new QLabel("<b>프로필 관리</b>", this));
    header->addStretch();
    auto addBtn = new QPushButton("추가", this);
    header->addWidget(addBtn);
    layout->addLayout(header);

    // Profile list
    m_list = new QListWidget(this);
    m_list->setIconSize(QSize(64, 40));
    layout->addWidget(m_list, 1);

    // Footer: 편집, 삭제
    auto footer = new QHBoxLayout();
    footer->addStretch();
    auto editBtn = new QPushButton("편집", this);
    auto delBtn = new QPushButton("삭제", this);
    footer->addWidget(editBtn);
    footer->addWidget(delBtn);
    layout->addLayout(footer);

    connect(addBtn, &QPushButton::clicked, this, &ProfilesDialog::addProfile);
    connect(editBtn, &QPushButton::clicked, this, &ProfilesDialog::editSelectedProfile);
    connect(delBtn, &QPushButton::clicked, this, &ProfilesDialog::deleteSelectedProfile);

    refreshList();
}

void ProfilesDialog::refreshList()
{
    m_list->clear();
    m_profiles = ProfileData::loadAll();
    for (const auto& p : m_profiles) {
        QString text = p.isDefault
            ? p.name
            : QString("%1\nMAC: %2").arg(p.name).arg(p.gatewayMac);
        auto item = new QListWidgetItem(text, m_list);
        item->setData(Qt::UserRole, p.id);

        QPixmap thumb = wallpaperThumbnail(p.wallpaperPath, p.id, QSize(64, 40));
        if (!thumb.isNull())
            item->setIcon(QIcon(thumb));
    }
}

void ProfilesDialog::addProfile()
{
    ProfileData d;
    d.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    d.isDefault = false;

    QProcess p;
    p.start("ip", {"neigh", "show", "default"});
    p.waitForFinished(2000);
    auto match = QRegularExpression("([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}").match(p.readAllStandardOutput());
    if (match.hasMatch()) d.gatewayMac = match.captured().toLower();

    ProfileEditDialog dlg(d, true, this);
    if (dlg.exec() == QDialog::Accepted) {
        auto profiles = ProfileData::loadAll();
        profiles.append(dlg.getProfile());
        ProfileData::saveAll(profiles);
        refreshList();
    }
}

void ProfilesDialog::editSelectedProfile()
{
    auto cur = m_list->currentItem();
    if (!cur) return;
    QString id = cur->data(Qt::UserRole).toString();
    auto profiles = ProfileData::loadAll();
    for (int i = 0; i < profiles.size(); ++i) {
        if (profiles[i].id == id) {
            ProfileEditDialog dlg(profiles[i], false, this);
            if (dlg.exec() == QDialog::Accepted) {
                profiles[i] = dlg.getProfile();
                ProfileData::saveAll(profiles);
                refreshList();
            }
            return;
        }
    }
}

void ProfilesDialog::deleteSelectedProfile()
{
    auto cur = m_list->currentItem();
    if (!cur) return;
    QString id = cur->data(Qt::UserRole).toString();
    auto profiles = ProfileData::loadAll();
    for (int i = 0; i < profiles.size(); ++i) {
        if (profiles[i].id == id) {
            if (profiles[i].isDefault) return;
            profiles.removeAt(i);
            ProfileData::saveAll(profiles);
            refreshList();
            return;
        }
    }
}

// ── ProfileEditDialog (macOS ProfileEditorView 와 동일) ─────

ProfileEditDialog::ProfileEditDialog(const ProfileData &profile, bool isNew, QWidget *parent)
    : QDialog(parent), m_profile(profile), m_isNew(isNew), m_progressDialog(nullptr), m_converter(nullptr)
{
    setWindowTitle(isNew ? "프로필 추가" : "프로필 편집");
    setMinimumWidth(480);

    auto layout = new QVBoxLayout(this);

    auto form = new QFormLayout();

    // 이름
    m_nameEdit = new QLineEdit(m_profile.name, this);
    m_nameEdit->setPlaceholderText("홈, 카페, 회사...");
    form->addRow("이름", m_nameEdit);

    // 네트워크 MAC
    m_macEdit = new QLineEdit(m_profile.gatewayMac, this);
    if (m_profile.isDefault) {
        m_macEdit->setReadOnly(true);
        m_macEdit->setPlaceholderText("없음 = 기본 프로필");
    }
    form->addRow("네트워크", m_macEdit);

    // 월페이퍼
    auto wpLayout = new QHBoxLayout();
    m_wallpaperEdit = new QLineEdit(m_profile.wallpaperPath, this);
    m_wallpaperEdit->setReadOnly(true);
    m_wallpaperEdit->setPlaceholderText("파일 없음");
    wpLayout->addWidget(m_wallpaperEdit, 1);
    auto browseBtn = new QPushButton("선택", this);
    wpLayout->addWidget(browseBtn);
    form->addRow("월페이퍼", wpLayout);

    // FPS (변환 시 출력 프레임레이트)
    m_fpsSpinBox = new QSpinBox(this);
    m_fpsSpinBox->setRange(10, 120);
    m_fpsSpinBox->setValue(m_profile.targetFps);
    m_fpsSpinBox->setSuffix(" fps");
    m_fpsSpinBox->setToolTip("H.265 변환 시 출력 프레임레이트");
    form->addRow("변환 FPS", m_fpsSpinBox);

    // 배터리 절약
    m_batteryPauseCheck = new QCheckBox("배터리 방전 시 일시정지", this);
    m_batteryPauseCheck->setChecked(m_profile.batteryPause);
    form->addRow("배터리 절약", m_batteryPauseCheck);

    layout->addLayout(form);

    // 미리보기
    m_previewLabel = new QLabel(this);
    m_previewLabel->setMinimumHeight(120);
    m_previewLabel->setMaximumHeight(160);
    m_previewLabel->setAlignment(Qt::AlignCenter);
    {
        QPixmap thumb = wallpaperThumbnail(m_profile.wallpaperPath, m_profile.id, QSize(320, 160));
        if (!thumb.isNull())
            m_previewLabel->setPixmap(thumb);
        else
            m_previewLabel->setText("미리보기 없음");
    }
    layout->addWidget(m_previewLabel);

    // 버튼
    auto btns = new QHBoxLayout();
    btns->addStretch();
    auto cancelBtn = new QPushButton("취소", this);
    m_saveBtn = new QPushButton("저장", this);
    btns->addWidget(cancelBtn);
    btns->addWidget(m_saveBtn);
    layout->addLayout(btns);

    connect(browseBtn, &QPushButton::clicked, this, &ProfileEditDialog::selectWallpaper);
    connect(cancelBtn, &QPushButton::clicked, this, &QDialog::reject);
    connect(m_saveBtn, &QPushButton::clicked, this, &ProfileEditDialog::save);
}

ProfileData ProfileEditDialog::getProfile() const { return m_profile; }

void ProfileEditDialog::selectWallpaper()
{
    auto file = QFileDialog::getOpenFileName(this, "월페이퍼 선택", QDir::homePath(),
        "미디어 (*.mp4 *.webm *.mov *.avi *.mkv *.jpg *.jpeg *.png *.gif);;모든 파일 (*)");
    if (file.isEmpty()) return;

    QFileInfo fi(file);
    static const QStringList videoExts = {"mp4", "webm", "mov", "avi", "mkv", "m4v", "flv", "wmv"};

    if (videoExts.contains(fi.suffix().toLower())) {
        startConversion(file);
    } else {
        m_profile.wallpaperPath = file;
        m_wallpaperEdit->setText(file);
        QPixmap px(file);
        if (!px.isNull())
            m_previewLabel->setPixmap(px.scaled(m_previewLabel->size(), Qt::KeepAspectRatioByExpanding, Qt::SmoothTransformation));
    }
}

void ProfileEditDialog::startConversion(const QString &sourcePath)
{
    QString wallpapersDir = QDir::homePath() + "/.ilko/wallpapers";
    QDir().mkpath(wallpapersDir);
    QString outputPath = wallpapersDir + "/" + m_profile.id + ".mp4";
    // Write to a temp file first; rename atomically on success so the old
    // file stays intact if conversion is interrupted or cancelled.
    // Keep the .mp4 extension so ffmpeg infers the correct container format.
    QString tmpPath = wallpapersDir + "/." + m_profile.id + "_tmp.mp4";

    // If a previous converter is running, kill it
    if (m_converter) {
        m_converter->kill();
        m_converter->waitForFinished(1000);
        m_converter->deleteLater();
        m_converter = nullptr;
    }

    m_progressDialog = new QProgressDialog(this);
    m_progressDialog->setWindowTitle("변환 중");
    m_progressDialog->setLabelText(QString("H.265 변환 중...\n%1").arg(QFileInfo(sourcePath).fileName()));
    m_progressDialog->setCancelButtonText("취소");
    m_progressDialog->setRange(0, 0);  // indeterminate
    m_progressDialog->setWindowModality(Qt::WindowModal);
    m_progressDialog->setMinimumDuration(0);
    m_progressDialog->show();
    m_saveBtn->setEnabled(false);

    m_converter = new QProcess(this);

    QStringList args = {
        "-i", sourcePath,
        "-c:v", "libx265",
        "-preset", "faster",
        "-crf", "28",
        "-r", QString::number(m_fpsSpinBox->value()),
        "-an",          // no audio — video wallpaper never plays audio
        "-threads", "0",
        "-y",
        tmpPath         // write to temp file
    };

    connect(m_progressDialog, &QProgressDialog::canceled, m_converter, &QProcess::kill);

    connect(m_converter, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, outputPath, tmpPath, sourcePath](int exitCode, QProcess::ExitStatus status) {
        m_progressDialog->close();
        m_progressDialog->deleteLater();
        m_progressDialog = nullptr;
        m_saveBtn->setEnabled(true);
        m_converter->deleteLater();
        m_converter = nullptr;

        if (exitCode == 0 && status == QProcess::NormalExit && QFile::exists(tmpPath)) {
            // Atomic replace: old file stays valid until new one is complete
            QFile::remove(outputPath);
            QFile::rename(tmpPath, outputPath);

            m_profile.wallpaperPath = outputPath;
            m_wallpaperEdit->setText(outputPath);

            // Regenerate thumbnail cache for updated video
            QString thumbDir = QDir::homePath() + "/.ilko/thumbnails";
            QString thumbPath = thumbDir + "/" + m_profile.id + ".jpg";
            QFile::remove(thumbPath);

            QPixmap thumb = wallpaperThumbnail(outputPath, m_profile.id, QSize(320, 160));
            if (!thumb.isNull())
                m_previewLabel->setPixmap(thumb);
            else
                m_previewLabel->setText("변환 완료 ✓");
        } else {
            // Failed or cancelled — discard the incomplete temp file
            QFile::remove(tmpPath);
            if (status == QProcess::NormalExit) {
                QMessageBox::warning(this, "변환 실패",
                    "H.265 변환에 실패했습니다.\n원본 파일을 사용합니다.");
                m_profile.wallpaperPath = sourcePath;
                m_wallpaperEdit->setText(sourcePath);
            }
            // If cancelled (CrashExit from kill), leave wallpaperPath as-is
        }
    });

    m_converter->start("ffmpeg", args);
}

void ProfileEditDialog::save()
{
    if (m_nameEdit->text().trimmed().isEmpty() || m_profile.wallpaperPath.isEmpty()) return;
    m_profile.name = m_nameEdit->text().trimmed();
    m_profile.gatewayMac = m_macEdit->text().trimmed();
    m_profile.targetFps = m_fpsSpinBox->value();
    m_profile.batteryPause = m_batteryPauseCheck->isChecked();
    accept();
}

// ── SettingsDialog ────────────────────────────────────────

SettingsDialog::SettingsDialog(QWidget *parent) : QDialog(parent)
{
    setWindowTitle("설정");
    setMinimumWidth(360);

    auto layout = new QVBoxLayout(this);
    layout->addWidget(new QLabel("<b>설정</b>", this));
    layout->addSpacing(8);

    // 저장 경로 안내
    auto storageInfo = new QLabel(
        QString("월페이퍼 저장 위치:\n%1/.ilko/wallpapers/").arg(QDir::homePath()), this);
    storageInfo->setWordWrap(true);
    layout->addWidget(storageInfo);

    layout->addStretch();

    auto clearBtn = new QPushButton("변환된 월페이퍼 삭제", this);
    clearBtn->setToolTip("~/.ilko/wallpapers/ 폴더 안의 변환된 파일을 모두 삭제합니다");
    layout->addWidget(clearBtn);

    auto closeBtn = new QPushButton("닫기", this);
    layout->addWidget(closeBtn, 0, Qt::AlignRight);

    connect(clearBtn, &QPushButton::clicked, this, &SettingsDialog::clearCache);
    connect(closeBtn, &QPushButton::clicked, this, &QDialog::accept);
}

void SettingsDialog::clearCache()
{
    auto reply = QMessageBox::question(this, "확인",
        "~/.ilko/wallpapers/ 폴더의 변환된 파일을 모두 삭제할까요?",
        QMessageBox::Yes | QMessageBox::No);
    if (reply == QMessageBox::Yes) {
        QDir(QDir::homePath() + "/.ilko/wallpapers").removeRecursively();
        QMessageBox::information(this, "완료", "삭제되었습니다.");
    }
}