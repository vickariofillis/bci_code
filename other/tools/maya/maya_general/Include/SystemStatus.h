/* 
 * File:   SystemStatus.h
 * Author: Raghavendra Pradyumna Pothukuchi and Sweta Yamini Pothukuchi
 */

/*
 * SystemStatus is used track the on/off status of the components of the systems - 
 * e.g., cores in a CPU. For a CPU, information for the physical cores and 
 * SMT (HyperThread) cores is separately maintained.
 */

#ifndef SYSTEMSTATUS_H
#define SYSTEMSTATUS_H

#include <string>
#include <cstdint>
#include <vector>

enum class SystemType {
    CPU
};

class SystemStatus {
public:
    SystemStatus(std::string name, SystemType systemType, uint32_t totalComponents);
    SystemStatus(std::string name, SystemType systemType);

    auto getName() {
        return name;
    }

    auto getUnitIds() {
        return unitIds;
    }

    auto getPhysicalUnitIds() {
        return physicalUnitIds;
    }

    auto getTotalActive() {
        return totalActiveUnits;
    }

    auto getTotalUnits() {
        return totalUnits;
    }

    auto getAllUnitStatus() {
        return unitStatus;
    }

    auto getUnitStatus(uint32_t unitId) {
        return unitStatus[unitId];
    }


    void setTotalUnits(uint32_t numComponents);
    void setUnitStatus(std::vector<bool> newStatus);
    void setUnitStatus(uint32_t componentId, bool newStatus);

    void print();
private:

    void updatePhysicalUnitInfo();
    SystemType systemType;
    uint32_t totalActiveUnits, totalActivePhysicalUnits;
    uint32_t totalUnits, totalPhysicalUnits;
    std::vector<bool> unitStatus, physicalUnitStatus;
    std::vector<uint32_t> unitIds, physicalUnitIds;
    std::string name;
    std::string presentCPUCoreFileName = "/sys/devices/system/cpu/present";
};

#endif /* SYSTEMSTATUS_H */
