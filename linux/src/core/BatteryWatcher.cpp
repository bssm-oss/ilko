#include "BatteryWatcher.h"

#include <QProcess>
#include <QFile>
#include <QDBusConnection>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QDBusReply>

namespace ilko {

BatteryWatcher::BatteryWatcher(QObject *parent)
    : QObject(parent)
    , m_timer(new QTimer(this))
    , m_percentage(0)
    , m_state(Unknown)
    , m_isPresent(false)
    , m_wasLow(false)
    , m_upowerInterface(nullptr)
{
    connect(m_timer, &QTimer::timeout, this, &BatteryWatcher::checkBattery);
}

BatteryWatcher::~BatteryWatcher() = default;

void BatteryWatcher::start()
{
    QDBusConnection dbus = QDBusConnection::systemBus();
    if (dbus.isConnected()) {
        m_upowerInterface = new QDBusInterface(
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower",
            "org.freedesktop.DBus.Properties",
            dbus,
            this
        );
    }

    checkBattery();
    m_timer->start(30000);
}

void BatteryWatcher::stop()
{
    m_timer->stop();
}

void BatteryWatcher::checkBattery()
{
    int prevPercentage = m_percentage;
    BatteryState prevState = m_state;

    if (m_upowerInterface && m_upowerInterface->isValid()) {
        updateFromUPower();
    } else {
        updateFromSysfs();
    }

    if (m_percentage != prevPercentage) {
        emit percentageChanged(m_percentage);
    }
    if (m_state != prevState) {
        emit stateChanged(m_state);
        emit chargingChanged(m_state == Charging);
    }

    bool isLow = m_percentage > 0 && m_percentage <= 15 && m_state != Charging;
    if (isLow != m_wasLow) {
        m_wasLow = isLow;
        emit lowBattery(isLow);
    }

    if (m_percentage != prevPercentage || m_state != prevState) {
        writeStateFile();
    }
}

void BatteryWatcher::writeStateFile()
{
    QString homeDir = QStandardPaths::writableLocation(QStandardPaths::HomeLocation);
    QString ilkoDir = homeDir + "/.ilko";
    QDir().mkpath(ilkoDir);

    QJsonObject obj;
    obj["percentage"] = m_percentage;
    obj["charging"] = (m_state == Charging);
    obj["low"] = (m_percentage > 0 && m_percentage <= 15 && m_state != Charging);

    QJsonDocument doc(obj);
    QFile file(ilkoDir + "/battery_state.json");
    if (file.open(QIODevice::WriteOnly)) {
        file.write(doc.toJson());
        file.close();
    }
}

static QString findBatteryPath()
{
    const QDir psDir("/sys/class/power_supply");
    for (const QString &entry : psDir.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        QFile typeFile(psDir.filePath(entry) + "/type");
        if (typeFile.open(QIODevice::ReadOnly)) {
            if (typeFile.readAll().trimmed() == "Battery") {
                typeFile.close();
                return psDir.filePath(entry);
            }
            typeFile.close();
        }
    }
    return {};
}

void BatteryWatcher::updateFromUPower()
{
    // UPower manager object has OnBattery bool but not per-device Percentage/State.
    // Use OnBattery for discharge detection; read percentage from sysfs.
    QDBusMessage reply = m_upowerInterface->call("GetAll", "org.freedesktop.UPower");
    if (reply.type() != QDBusMessage::ReplyMessage) {
        updateFromSysfs();
        return;
    }

    QVariantMap map = qdbus_cast<QVariantMap>(reply.arguments().first());
    if (!map.contains("OnBattery")) {
        updateFromSysfs();
        return;
    }

    bool onBattery = map.value("OnBattery").toBool();
    m_state = onBattery ? Discharging : Charging;
    m_isPresent = true;

    const QString batPath = findBatteryPath();
    if (!batPath.isEmpty()) {
        QFile capacityFile(batPath + "/capacity");
        if (capacityFile.open(QIODevice::ReadOnly)) {
            m_percentage = capacityFile.readAll().trimmed().toInt();
            capacityFile.close();
        }
    }
}

void BatteryWatcher::updateFromSysfs()
{
    const QString batPath = findBatteryPath();
    if (batPath.isEmpty()) return;

    QFile capacityFile(batPath + "/capacity");
    if (capacityFile.open(QIODevice::ReadOnly)) {
        m_percentage = capacityFile.readAll().trimmed().toInt();
        capacityFile.close();
        m_isPresent = true;
    }

    QFile statusFile(batPath + "/status");
    if (statusFile.open(QIODevice::ReadOnly)) {
        const QString status = statusFile.readAll().trimmed();
        if (status == "Charging") m_state = Charging;
        else if (status == "Discharging") m_state = Discharging;
        else if (status == "Full") m_state = Full;
        else m_state = Unknown;
        statusFile.close();
    }
}

}