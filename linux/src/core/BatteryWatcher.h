#pragma once

#include <QObject>
#include <QTimer>
#include <QDBusInterface>
#include <QDir>

namespace ilko {

class BatteryWatcher : public QObject
{
    Q_OBJECT

public:
    enum BatteryState {
        Discharging,
        Charging,
        Full,
        Unknown
    };

    explicit BatteryWatcher(QObject *parent = nullptr);
    ~BatteryWatcher();

    void start();
    void stop();

    int percentage() const { return m_percentage; }
    BatteryState state() const { return m_state; }
    bool isPresent() const { return m_isPresent; }

signals:
    void percentageChanged(int percentage);
    void stateChanged(BatteryState state);
    void chargingChanged(bool charging);
    void lowBattery(bool low);

private slots:
    void checkBattery();

private:
    void updateFromUPower();
    void updateFromSysfs();
    void writeStateFile();

    QTimer *m_timer;
    int m_percentage;
    BatteryState m_state;
    bool m_isPresent;
    bool m_wasLow;
    QDBusInterface *m_upowerInterface;
};

}