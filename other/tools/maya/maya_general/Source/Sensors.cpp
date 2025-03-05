/* 
 * File:   Sensors.cpp
 * Author: Raghavendra Pradyumna Pothukuchi and Sweta Yamini Pothukuchi
 */

#include "Sensors.h"
#include "debug.h"
#include "SystemStatus.h"
#include <fstream>
#include <iostream>
#include <memory>
#include <cmath>
#include <stdint.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>
#include <errno.h>
#include <cstring>
#include <dirent.h>
#include <vector>
#include <unordered_map>
#include <functional>

// -----------------------------------------------------------------------------
// Helper: Create a Vector of given size filled with 0.0.
// (Assumes Vector takes ownership of the allocated array.)
static Vector makeVector(size_t n) {
    double* arr = new double[n];
    for (size_t i = 0; i < n; ++i)
        arr[i] = 0.0;
    return Vector(arr, n);
}

// -----------------------------------------------------------------------------
// coreStatus is used to track the on/off status of cores.
extern SystemStatus coreStatus;

// -----------------------------------------------------------------------------
// Sensor Base Class Implementation
// -----------------------------------------------------------------------------
Sensor::Sensor(std::string sname)
    : name(sname), width(1),
      out(std::make_shared<OutputPort>(sname, std::initializer_list<std::string>({ sname })))
{
    values = makeVector(width);
    prevValues = makeVector(width);
#ifdef DEBUG
    std::cout << "Sensor '" << name << "' default width " << width << std::endl;
#endif
    prevSampleTime = sampleTime = Clock::now();
}

Sensor::Sensor(std::string sname, std::initializer_list<std::string> pNames)
    : name(sname), width(pNames.size()),
      out(std::make_shared<OutputPort>(sname, pNames))
{
    values = makeVector(width);
    prevValues = makeVector(width);
#ifdef DEBUG
    std::cout << "Sensor '" << name << "' width " << width << std::endl;
#endif
    prevSampleTime = sampleTime = Clock::now();
}

std::string Sensor::getName() {
    return name;
}

void Sensor::updateValuesFromSystem() {
    prevValues = values; // assume Vector supports operator=
    readFromSystem();
    out->updateValuesToPort(values);
}

void Sensor::readFromSystem() {
    // Base implementation: do nothing.
}

Vector Sensor::measureReadLatency() {
    Vector latencyResults = makeVector(1);
    auto init = Clock::now();
    updateValuesFromSystem();
    auto end = Clock::now();
    latencyResults[0] = std::chrono::duration_cast<MicroSec>(end - init).count();
#ifdef DEBUG
    std::cout << "Read Latency for " << name << ": " << latencyResults[0] << " us" << std::endl;
#endif
    return latencyResults;
}

// -----------------------------------------------------------------------------
// Time Sensor Implementation
// -----------------------------------------------------------------------------
Time::Time(std::string name) : Sensor(name) {
    readFromSystem();
}

void Time::readFromSystem() {
    clock_gettime(CLOCK_REALTIME, &rawTime);
    values[0] = (double)rawTime.tv_sec + ((double)rawTime.tv_nsec) * 1e-9;
#ifdef DEBUG
    std::cout << "Time: " << rawTime.tv_sec << "." << rawTime.tv_nsec 
              << " (" << values[0] << ")" << std::endl;
#endif
}

// -----------------------------------------------------------------------------
// CPUPowerSensor Implementation
// -----------------------------------------------------------------------------
CPUPowerSensor::CPUPowerSensor(std::string name)
    : Sensor(name), energyCtr(0)
{
    values = makeVector(1);
    values[0] = 0.0;
    std::string raplName;
    std::ifstream raplFile;
    raplFile.open(coreEnergyDirName + "name");
    raplFile >> raplName;
    raplFile.close();
    if (raplName.find("core") != std::string::npos) {
        energyFileNames.push_back(coreEnergyDirName + energyFilePrefix);
#ifdef DEBUG
        std::cout << "CPUPowerSensor: Pushing " << coreEnergyDirName + energyFilePrefix << std::endl;
#endif
    } else {
        energyFileNames.push_back(pkgEnergyDirName1 + energyFilePrefix);
        energyFileNames.push_back(pkgEnergyDirName2 + energyFilePrefix);
#ifdef DEBUG
        std::cout << "CPUPowerSensor: Pushing " << pkgEnergyDirName1 + energyFilePrefix << std::endl;
        std::cout << "CPUPowerSensor: Pushing " << pkgEnergyDirName2 + energyFilePrefix << std::endl;
#endif
    }
}

void CPUPowerSensor::readFromSystem() {
    double ctrValue = 0.0, tmp = 0.0;
    std::ifstream powerFile;
    for (auto& energyFileName : energyFileNames) {
        powerFile.open(energyFileName);
        powerFile >> tmp;
        powerFile.close();
        ctrValue += tmp;
    }
    double newEnergy = ctrValue - energyCtr;
    energyCtr = ctrValue;
    sampleTime = Clock::now();
    auto deltaTime = std::chrono::duration_cast<MicroSec>(sampleTime - prevSampleTime).count();
    prevSampleTime = sampleTime;
    values[0] = (deltaTime > 0) ? newEnergy / (double)deltaTime : 0.0;
#ifdef DEBUG
    std::cout << "CPUPowerSensor: deltaEnergy " << newEnergy << ", elapsed " 
              << deltaTime << " us, power " << values[0] << std::endl;
#endif
}

// -----------------------------------------------------------------------------
// CPUTempSensor Implementation
// -----------------------------------------------------------------------------
CPUTempSensor::CPUTempSensor(std::string name) : Sensor(name) {
    DIR* coretempDir;
    struct dirent* coretempDirEntry;
    uint32_t dirOpenFailure = 0;
    for (auto& coretempDirName : coretempDirNames) {
        if ((coretempDir = opendir(coretempDirName.c_str())) != NULL) {
            while ((coretempDirEntry = readdir(coretempDir)) != NULL) {
                std::string tempfileName(coretempDirEntry->d_name);
                if (tempfileName.find("input") != std::string::npos &&
                    tempfileName.compare("temp1_input") != 0) {
                    tempFileNames.push_back(coretempDirName + tempfileName);
#ifdef DEBUG
                    std::cout << "CPUTempSensor: found " << coretempDirName + tempfileName << std::endl;
#endif
                }
            }
            closedir(coretempDir);
        } else {
            dirOpenFailure += 1;
        }
    }
    if (dirOpenFailure == coretempDirNames.size()) {
        std::cout << "CPUTempSensor: Cannot open any of directories listed!" << std::endl;
        std::exit(EXIT_FAILURE);
    }
    // Initialize coreTemps with one value per file.
    coreTemps = makeVector(tempFileNames.size());
}

void CPUTempSensor::readFromSystem() {
    double newValue;
    values = makeVector(1);
    values[0] = 0.0;
    std::ifstream tempFile;
    size_t i = 0;
    for (auto& tempFileName : tempFileNames) {
#ifdef DEBUG
        std::cout << "CPUTempSensor: Reading from " << tempFileName << std::endl;
#endif
        tempFile.open(tempFileName);
        tempFile >> newValue; // in millidegrees Celsius
        tempFile.close();
        if (newValue > values[0])
            values[0] = newValue;
        ++i;
    }
    // Convert millidegrees Celsius to degrees Celsius.
    values[0] /= 1000.0;
#ifdef DEBUG
    std::cout << "CPUTempSensor: Core temperature = " << values[0] << " °C" << std::endl;
#endif
}

// -----------------------------------------------------------------------------
// DRAMPowerSensor Implementation
// -----------------------------------------------------------------------------
DRAMPowerSensor::DRAMPowerSensor(std::string name) : Sensor(name), energyCtr(0) {
    values = makeVector(1);
    values[0] = 0.0;
}

void DRAMPowerSensor::readFromSystem() {
    double ctrValue;
    std::ifstream powerFile(energyFileName);
    powerFile >> ctrValue;
    double newEnergy = ctrValue - energyCtr;
    energyCtr = ctrValue;
    sampleTime = Clock::now();
    auto deltaTime = std::chrono::duration_cast<MicroSec>(sampleTime - prevSampleTime).count();
    prevSampleTime = sampleTime;
    values[0] = (deltaTime > 0) ? newEnergy / (double)deltaTime : 0.0;
#ifdef DEBUG
    std::cout << "DRAMPowerSensor: deltaEnergy " << newEnergy << ", elapsed " 
              << deltaTime << " us, DRAM power " << values[0] << std::endl;
#endif
}

// -----------------------------------------------------------------------------
// PerfStatCounters Implementation
// -----------------------------------------------------------------------------
PerfStatCounters::PerfStatCounters(uint32_t coreId, std::initializer_list<perf_type_id> typeIds,
                                   std::initializer_list<perf_hw_id> ctrNames)
{
    if (typeIds.size() != ctrNames.size()) {
        std::cout << "PerfStatCounters: Number of counter types and names don't match" << std::endl;
        std::exit(EXIT_FAILURE);
    }
    int numCounters = ctrNames.size();
    for (int i = 0; i < numCounters; i++) {
        values.push_back(0);
        fds.push_back(-1);
    }
    createCounterFds(coreId, typeIds, ctrNames);
    prevValues = values;
}

void PerfStatCounters::createCounterFds(uint32_t coreId,
    std::initializer_list<perf_type_id> typeIds,
    std::initializer_list<perf_hw_id> ctrNames)
{
    if (typeIds.size() != ctrNames.size()) {
        std::cout << "PerfStatCounters: Number of counter types and names don't match" << std::endl;
        std::exit(EXIT_FAILURE);
    }
    std::vector<perf_type_id> typeIdList(typeIds);
    std::vector<perf_hw_id> ctrNameList(ctrNames);
    int numCounters = ctrNames.size();
    struct perf_event_attr eventAttr;
    memset(&eventAttr, 0, sizeof(eventAttr));
    eventAttr.size = sizeof(eventAttr);
    for (int i = 0; i < numCounters; i++) {
        eventAttr.type = typeIdList[i];
        eventAttr.config = ctrNameList[i];
        if (i == 0) {
            eventAttr.disabled = 1;
            fds[i] = syscall(__NR_perf_event_open, &eventAttr, -1, coreId, -1, 0);
        } else {
            eventAttr.disabled = 0;
            fds[i] = syscall(__NR_perf_event_open, &eventAttr, -1, coreId, fds[0], 0);
        }
        if (numCounters == 1)
            eventAttr.disabled = 0;
#ifdef DEBUG
        std::cout << "PerfStatCounters: fd[" << i << "] = " << fds[i] << std::endl;
#endif
        if (fds[i] == -1) {
            if (errno == ENOENT) {
                std::cerr << "PerfStatCounters: Cannot create perf counter for core " << coreId
                          << ", event index " << i << ": Not supported. Skipping this event." << std::endl;
                fds[i] = -2; // Mark as unsupported.
                values[i] = 0;
                prevValues[i] = 0;
                continue;
            } else {
                std::cerr << "PerfStatCounters: Cannot create perf counter for core " << coreId
                          << ", event index " << i << ": " << strerror(errno) << std::endl;
                std::exit(EXIT_FAILURE);
            }
        }
    }
}

void PerfStatCounters::enable() {
    for (auto& fd : fds) {
        if (fd >= 0) {
            ioctl(fd, PERF_EVENT_IOC_RESET);
            ioctl(fd, PERF_EVENT_IOC_ENABLE);
        }
    }
}

void PerfStatCounters::reenable() {
    for (auto& fd : fds) {
        if (fd >= 0) {
            ioctl(fd, PERF_EVENT_IOC_ENABLE);
        }
    }
}

void PerfStatCounters::disable() {
    for (size_t i = 0; i < fds.size(); i++) {
        if (fds[i] >= 0) {
            ioctl(fds[i], PERF_EVENT_IOC_DISABLE, 0);
            close(fds[i]);
            fds[i] = -1;
            values[i] = 0;
            prevValues[i] = 0;
        }
    }
}

void PerfStatCounters::updateCounters() {
    prevValues = values;
    uint64_t value;
    int numBytesRead = -1;
    for (size_t i = 0; i < fds.size(); i++) {
        // If this event is marked unsupported, skip it.
        if (fds[i] < 0) {
            values[i] = 0;
            continue;
        }
        numBytesRead = read(fds[i], &value, sizeof(value));
        if (numBytesRead != sizeof(value)) {
            std::cout << "PerfStatCounters: Cannot read perf counter at index " << i << std::endl;
            std::exit(EXIT_FAILURE);
        }
        values[i] = value;
    }
}

Vector PerfStatCounters::getValues() {
    return Vector(values);
}

Vector PerfStatCounters::getDeltaValues() {
    Vector curr(values), prev(prevValues);
    return curr - prev;
}

double PerfStatCounters::getValue(uint32_t ctrNum) {
    return static_cast<double>(values[ctrNum]);
}

// -----------------------------------------------------------------------------
// CorePerfSensor Implementation
// -----------------------------------------------------------------------------
CorePerfSensor::CorePerfSensor(std::string name, uint32_t coreId_)
    : coreId(coreId_),
      Sensor(name, { name + std::to_string(coreId_) + "_BIPS",
                     name + std::to_string(coreId_) + "_MPKI" })
{
    sampleTime = Clock::now();
    prevSampleTime = sampleTime;
    {
        std::initializer_list<perf_type_id> types { PERF_TYPE_HARDWARE };
        std::initializer_list<perf_hw_id> events { static_cast<perf_hw_id>(PERF_COUNT_HW_INSTRUCTIONS) };
        instCtr = std::unique_ptr<PerfStatCounters>( new PerfStatCounters(coreId, types, events) );
    }
    {
        std::initializer_list<perf_type_id> types { PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE };
        std::initializer_list<perf_hw_id> events { static_cast<perf_hw_id>(PERF_COUNT_HW_CACHE_REFERENCES),
                                                   static_cast<perf_hw_id>(PERF_COUNT_HW_CACHE_MISSES) };
        cacheCtr = std::unique_ptr<PerfStatCounters>( new PerfStatCounters(coreId, types, events) );
    }
    shutDown = false;
    instCtr->enable();
    cacheCtr->enable();
    readFromSystem();
#ifdef DEBUG
    std::cout << "CorePerfSensor: First values for core " << coreId << ": " << values << std::endl;
#endif
}

CorePerfSensor::~CorePerfSensor() {
    instCtr->disable();
    cacheCtr->disable();
}

void CorePerfSensor::handleShutDown() {
#ifdef DEBUG
    std::cout << "CorePerfSensor: Shutting down counters on core " << coreId << std::endl;
#endif
    instCtr->disable();
    cacheCtr->disable();
    shutDown = true;
}

void CorePerfSensor::handleReactivation() {
#ifdef DEBUG
    std::cout << "CorePerfSensor: Reactivating counters on core " << coreId << std::endl;
#endif
    {
        std::initializer_list<perf_type_id> types { PERF_TYPE_HARDWARE };
        std::initializer_list<perf_hw_id> events { static_cast<perf_hw_id>(PERF_COUNT_HW_INSTRUCTIONS) };
        instCtr->createCounterFds(coreId, types, events);
    }
    {
        std::initializer_list<perf_type_id> types { PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE };
        std::initializer_list<perf_hw_id> events { static_cast<perf_hw_id>(PERF_COUNT_HW_CACHE_REFERENCES),
                                                   static_cast<perf_hw_id>(PERF_COUNT_HW_CACHE_MISSES) };
        cacheCtr->createCounterFds(coreId, types, events);
    }
    sampleTime = Clock::now();
    prevSampleTime = sampleTime;
    instCtr->reenable();
    cacheCtr->reenable();
    shutDown = false;
}

void CorePerfSensor::readFromSystem() {
    sampleTime = Clock::now();
    double deltaTime = std::chrono::duration_cast<NanoSec>(sampleTime - prevSampleTime).count();
    prevSampleTime = sampleTime;
    Vector perCoreNewInstVals, perCoreNewCacheCtrVals;
    coreBips = 0.0;
    coreMpki = 0.0;
    if (coreStatus.getUnitStatus(coreId) == false && !shutDown) {
        handleShutDown();
    } else if (coreStatus.getUnitStatus(coreId) == true && shutDown) {
        handleReactivation();
    } else {
        instCtr->updateCounters();
        cacheCtr->updateCounters();
        perCoreNewInstVals = instCtr->getDeltaValues();
        perCoreNewCacheCtrVals = cacheCtr->getDeltaValues();
        coreBips = (deltaTime > 0) ? perCoreNewInstVals[0] / deltaTime : 0.0;
        coreMpki = (perCoreNewInstVals[0] > 0) ? perCoreNewCacheCtrVals[1] * 1000.0 / perCoreNewInstVals[0] : 0.0;
    }
    values = makeVector(2);
    values[0] = coreBips;
    values[1] = coreMpki;
#ifdef DEBUG
    std::cout << "CorePerfSensor (core " << coreId << "): Instructions: " << perCoreNewInstVals[0]
              << ", BIPS: " << values[0] << ", BranchMisses: " << perCoreNewCacheCtrVals[1]
              << ", MPKI: " << values[1] << std::endl;
#endif      
}

// -----------------------------------------------------------------------------
// CPUPerfSensor Implementation
// -----------------------------------------------------------------------------
CPUPerfSensor::CPUPerfSensor(std::string name, std::vector<uint32_t> coreIds_)
    : coreIds(coreIds_),
      Sensor(name, { name + "_CPUCycles",
                     name + "_BIPS",
                     name + "_BranchMisses",
                     name + "_BranchMissPerc",
                     name + "_LlcRefs",
                     name + "_LlcMisses",
                     name + "_LlcMissRate",
                     name + "_BusCycles",
                     name + "_BusCyclesPerc",
                     name + "_SW_CPUClock",
                     name + "_SW_TaskClock",
                     name + "_SW_PageFaults",
                     name + "_SW_CPUMigrations",
                     name + "_SW_ContextSwitches",
                     name + "_SW_AlignmentFaults",
                     name + "_SW_EmulationFaults" })
{
    // Initialize sensor output vector to 16 elements.
    values = makeVector(16);
    prevValues = makeVector(16);
    sampleTime = Clock::now();
    prevSampleTime = sampleTime;
    // For each core, create four groups and enable them.
    groupCounters.resize(coreIds.size());
    shutDown.resize(coreIds.size(), false);
    for (size_t i = 0; i < coreIds.size(); i++) {
        uint32_t coreId = coreIds[i];
        std::vector<std::unique_ptr<PerfStatCounters>> groups;
        groups.resize(4);
        // Group 0: Hardware group 0 (4 events)
        {
            std::initializer_list<perf_type_id> types { 
                PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE,
                PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE
            };
            std::initializer_list<perf_hw_id> events {
                static_cast<perf_hw_id>(PERF_COUNT_HW_REF_CPU_CYCLES),
                static_cast<perf_hw_id>(PERF_COUNT_HW_INSTRUCTIONS),
                static_cast<perf_hw_id>(PERF_COUNT_HW_BRANCH_INSTRUCTIONS),
                static_cast<perf_hw_id>(PERF_COUNT_HW_BRANCH_MISSES)
            };
            groups[0] = std::unique_ptr<PerfStatCounters>( new PerfStatCounters(coreId, types, events) );
        }
        // Group 1: Hardware group 1 (3 events)
        {
            std::initializer_list<perf_type_id> types {
                PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE
            };
            std::initializer_list<perf_hw_id> events {
                static_cast<perf_hw_id>(PERF_COUNT_HW_CACHE_REFERENCES),
                static_cast<perf_hw_id>(PERF_COUNT_HW_CACHE_MISSES),
                static_cast<perf_hw_id>(PERF_COUNT_HW_BUS_CYCLES)
            };
            groups[1] = std::unique_ptr<PerfStatCounters>( new PerfStatCounters(coreId, types, events) );
        }
        // Group 2: Software group 2 (4 events)
        {
            std::initializer_list<perf_type_id> types {
                PERF_TYPE_SOFTWARE, PERF_TYPE_SOFTWARE,
                PERF_TYPE_SOFTWARE, PERF_TYPE_SOFTWARE
            };
            std::initializer_list<perf_hw_id> events {
                static_cast<perf_hw_id>(PERF_COUNT_SW_CPU_CLOCK),
                static_cast<perf_hw_id>(PERF_COUNT_SW_TASK_CLOCK),
                static_cast<perf_hw_id>(PERF_COUNT_SW_PAGE_FAULTS),
                static_cast<perf_hw_id>(PERF_COUNT_SW_CPU_MIGRATIONS)
            };
            groups[2] = std::unique_ptr<PerfStatCounters>( new PerfStatCounters(coreId, types, events) );
        }
        // Group 3: Software group 3 (3 events)
        {
            std::initializer_list<perf_type_id> types {
                PERF_TYPE_SOFTWARE, PERF_TYPE_SOFTWARE, PERF_TYPE_SOFTWARE
            };
            std::initializer_list<perf_hw_id> events {
                static_cast<perf_hw_id>(PERF_COUNT_SW_CONTEXT_SWITCHES),
                static_cast<perf_hw_id>(PERF_COUNT_SW_ALIGNMENT_FAULTS),
                static_cast<perf_hw_id>(PERF_COUNT_SW_EMULATION_FAULTS)
            };
            groups[3] = std::unique_ptr<PerfStatCounters>( new PerfStatCounters(coreId, types, events) );
        }
        groupCounters[i] = std::move(groups);
        // Enable all groups for this core.
        for (int j = 0; j < 4; j++)
            groupCounters[i][j]->enable();
    }
}

CPUPerfSensor::~CPUPerfSensor() {
    for (size_t i = 0; i < groupCounters.size(); i++) {
        for (auto &grp : groupCounters[i]) {
            if (grp)
                grp->disable();
        }
    }
}

void CPUPerfSensor::handleShutDown(uint32_t coreId) {
    size_t idx = coreId; // assuming coreId is a valid index
#ifdef DEBUG
    std::cout << "CPUPerfSensor: Shutting down counters on core " << coreId << std::endl;
#endif
    for (auto &grp : groupCounters[idx])
        if (grp)
            grp->disable();
    shutDown[idx] = true;
}

void CPUPerfSensor::handleReactivation(uint32_t coreId) {
    size_t idx = coreId;
#ifdef DEBUG
    std::cout << "CPUPerfSensor: Reactivating counters on core " << coreId << std::endl;
#endif
    {
        std::initializer_list<perf_type_id> types { 
            PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE,
            PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE
        };
        std::initializer_list<perf_hw_id> events {
            static_cast<perf_hw_id>(PERF_COUNT_HW_REF_CPU_CYCLES),
            static_cast<perf_hw_id>(PERF_COUNT_HW_INSTRUCTIONS),
            static_cast<perf_hw_id>(PERF_COUNT_HW_BRANCH_INSTRUCTIONS),
            static_cast<perf_hw_id>(PERF_COUNT_HW_BRANCH_MISSES)
        };
        groupCounters[idx][0]->createCounterFds(coreId, types, events);
    }
    {
        std::initializer_list<perf_type_id> types {
            PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE, PERF_TYPE_HARDWARE
        };
        std::initializer_list<perf_hw_id> events {
            static_cast<perf_hw_id>(PERF_COUNT_HW_CACHE_REFERENCES),
            static_cast<perf_hw_id>(PERF_COUNT_HW_CACHE_MISSES),
            static_cast<perf_hw_id>(PERF_COUNT_HW_BUS_CYCLES)
        };
        groupCounters[idx][1]->createCounterFds(coreId, types, events);
    }
    {
        std::initializer_list<perf_type_id> types {
            PERF_TYPE_SOFTWARE, PERF_TYPE_SOFTWARE,
            PERF_TYPE_SOFTWARE, PERF_TYPE_SOFTWARE
        };
        std::initializer_list<perf_hw_id> events {
            static_cast<perf_hw_id>(PERF_COUNT_SW_CPU_CLOCK),
            static_cast<perf_hw_id>(PERF_COUNT_SW_TASK_CLOCK),
            static_cast<perf_hw_id>(PERF_COUNT_SW_PAGE_FAULTS),
            static_cast<perf_hw_id>(PERF_COUNT_SW_CPU_MIGRATIONS)
        };
        groupCounters[idx][2]->createCounterFds(coreId, types, events);
    }
    {
        std::initializer_list<perf_type_id> types {
            PERF_TYPE_SOFTWARE, PERF_TYPE_SOFTWARE, PERF_TYPE_SOFTWARE
        };
        std::initializer_list<perf_hw_id> events {
            static_cast<perf_hw_id>(PERF_COUNT_SW_CONTEXT_SWITCHES),
            static_cast<perf_hw_id>(PERF_COUNT_SW_ALIGNMENT_FAULTS),
            static_cast<perf_hw_id>(PERF_COUNT_SW_EMULATION_FAULTS)
        };
        groupCounters[idx][3]->createCounterFds(coreId, types, events);
    }
    for (int j = 0; j < 4; j++)
        groupCounters[idx][j]->reenable();
    shutDown[idx] = false;
}

void CPUPerfSensor::readFromSystem() {
    sampleTime = Clock::now();
    double deltaTime = std::chrono::duration_cast<NanoSec>(sampleTime - prevSampleTime).count();
    prevSampleTime = sampleTime;
    // Create aggregate vectors for each group.
    Vector agg0 = makeVector(4);  // Group 0: 4 events
    Vector agg1 = makeVector(3);  // Group 1: 3 events
    Vector agg2 = makeVector(4);  // Group 2: 4 events
    Vector agg3 = makeVector(3);  // Group 3: 3 events

    // For each core, update all groups and accumulate their delta values.
    for (size_t i = 0; i < coreIds.size(); i++) {
        uint32_t coreId = coreIds[i];
        if (coreStatus.getUnitStatus(coreId) == false) {
            if (!shutDown[i])
                handleShutDown(coreId);
            continue;
        } else if (shutDown[i]) {
            handleReactivation(coreId);
        }
        for (int j = 0; j < 4; j++) {
            groupCounters[i][j]->updateCounters();
            Vector delta = groupCounters[i][j]->getDeltaValues();
            if (j == 0)
                agg0 = agg0 + delta;
            else if (j == 1)
                agg1 = agg1 + delta;
            else if (j == 2)
                agg2 = agg2 + delta;
            else if (j == 3)
                agg3 = agg3 + delta;
        }
    }
    // Now compute the final sensor output.
    // Group 0 (Hardware group 0):
    values[0] = agg0[0]; // Perf_HW_CPUCycles
    values[1] = (deltaTime > 0) ? agg0[1] / deltaTime : 0.0; // Perf_HW_BIPS
    values[2] = agg0[3]; // Perf_HW_BranchMisses
    values[3] = (agg0[2] > 0) ? agg0[3] / agg0[2] : 0.0; // Perf_HW_BranchMissPerc

    // Group 1 (Hardware group 1):
    values[4] = agg1[0]; // Perf_HW_LlcRefs
    values[5] = agg1[1]; // Perf_HW_LlcMisses
    values[6] = (agg1[0] > 0) ? agg1[1] / agg1[0] : 0.0; // Perf_HW_LlcMissRate
    values[7] = agg1[2]; // Perf_HW_BusCycles
    values[8] = (agg0[1] > 0) ? agg1[2] / agg0[1] : 0.0; // Perf_HW_BusCyclesPerc

    // Group 2 (Software group 2):
    values[9]  = agg2[0]; // Perf_SW_CPUClock
    values[10] = agg2[1]; // Perf_SW_TaskClock
    values[11] = agg2[2]; // Perf_SW_PageFaults
    values[12] = agg2[3]; // Perf_SW_CPUMigrations

    // Group 3 (Software group 3):
    values[13] = agg3[0]; // Perf_SW_ContextSwitches
    values[14] = agg3[1]; // Perf_SW_AlignmentFaults
    values[15] = agg3[2]; // Perf_SW_EmulationFaults

#ifdef DEBUG
    std::cout << "CPUPerfSensor outputs: " << values << std::endl;
#endif
}

// -----------------------------------------------------------------------------
// Dummy Implementation
// -----------------------------------------------------------------------------
Dummy::Dummy(std::string name) :
    inp(std::make_shared<InputPort>(name))
{
}

Dummy::Dummy(std::string name, std::initializer_list<std::string> portNames) :
    inp(std::make_shared<InputPort>(name, portNames))
{
}

Vector Dummy::readInputs() {
    return inp->updateValuesFromPort();
}
