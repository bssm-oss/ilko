#pragma once

#include <QObject>
#include <memory>

class SwitchController;

namespace ilko {

class Application : public QObject
{
    Q_OBJECT

public:
    explicit Application(QObject *parent = nullptr);
    ~Application();

    void initialize();

    SwitchController *switchController() const;

    // 시작 시 하이브리드 GPU가 감지되어 절전 설정이 새로 적용됐으면 true
    bool wasGpuPowerSavingApplied() const;

private slots:
    void onScreenLockChanged(bool active);

private:
    void updatePlayerControl();

    class Impl;
    std::unique_ptr<Impl> d;
};

}
