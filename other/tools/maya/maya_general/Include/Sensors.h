/* 
 * File:   Sensors.h
 * Author: Raghavendra Pradyumna Pothukuchi and Sweta Yamini Pothukuchi
 */

/*
 * Declare all the sensors you need here. The base class for any sensor is the 
 * "Sensor" class. Any new sensor inherits this class and updates the 
 * readFromSystem() function. This function is used to read the sensor value from 
 * the appropriate system counters/files.
 * 
 * There are two sensors defined here: Time, Power. A few other sensors: CPU Temperature,  
 * Performance (Throughput, in Billions of Instructions Per Second (BIPS)) are 
 * commented but can be enabled for other purposes if desired.
 */

#ifndef SENSORS_H
#define SENSORS_H

#include "Abstractions.h"
#include "MathSupport.h"
#include <string>
#include <chrono>
#include <memory>
#include <vector>
#include <linux/perf_event.h>
#include <time.h>

class Sensor {
public:
    using Clock = std::chrono::steady_clock;
    using TimePoint = std::chrono::time_point<Clock>;
    using NanoSec = std::chrono::nanoseconds;
    using MicroSec = std::chrono::microseconds;
    using MilliSec = std::chrono::milliseconds;
    using Sec = std::chrono::seconds;

    Sensor(std::string sname, std::initializer_list<std::string> pnames);
    Sensor(std::string sname);
    virtual void updateValuesFromSystem();
    std::string getName();

    std::shared_ptr<OutputPort> out;
    Vector measureReadLatency(); // measure the delay of reading values from system

protected:
    virtual void readFromSystem();
    std::string name;
    Vector values, prevValues; // current values and previous values of sensors
    uint32_t width; // number of values, default is 1
    TimePoint sampleTime, prevSampleTime;
};

class Time : public Sensor {
public:
    Time(std::string name);
protected:
    void readFromSystem() override;
private:
    struct timespec rawTime;
};

class CPUPowerSensor : public Sensor {
public:
    CPUPowerSensor(std::string name);
protected:
    void readFromSystem() override;
private:
    std::string coreEnergyDirName = "/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/",
                pkgEnergyDirName1   = "/sys/class/powercap/intel-rapl/intel-rapl:0/",
                pkgEnergyDirName2   = "/sys/class/powercap/intel-rapl/intel-rapl:1/",
                energyFilePrefix    = "energy_uj";
    std::vector<std::string> energyFileNames;
    double energyCtr;
};

class CPUTempSensor : public Sensor {
public:
    CPUTempSensor(std::string name);
protected:
    void readFromSystem() override;
private:
    std::vector<std::string> coretempDirNames = { "/sys/devices/platform/coretemp.0/hwmon/hwmon0/",
                                                   "/sys/devices/platform/coretemp.0/hwmon/hwmon1/",
                                                   "/sys/devices/platform/coretemp.0/hwmon/hwmon2/",
                                                   "/sys/devices/platform/coretemp.1/hwmon/hwmon1/" };
    std::vector<std::string> tempFileNames;
    Vector coreTemps; // individual core temperatures
};

class DRAMPowerSensor : public Sensor {
public:
    DRAMPowerSensor(std::string name);
protected:
    void readFromSystem() override;
private:
    std::string energyFileName = "/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:1/energy_uj";
    double energyCtr;
};
 
// For Linux Perf Counters (see http://web.eece.maine.edu/~vweaver/projects/perf_events/perf_event_open.html)
class PerfStatCounters {
public:
    PerfStatCounters(uint32_t coreId, std::initializer_list<perf_type_id> typeIds, std::initializer_list<perf_hw_id> ctrNames);
    void createCounterFds(uint32_t coreId, std::initializer_list<perf_type_id> typeIds, std::initializer_list<perf_hw_id> ctrNames);
    void enable();
    void reenable();
    void disable();
    void updateCounters();
    Vector getValues();
    Vector getDeltaValues();
    double getValue(uint32_t ctrNum);
private:
    std::vector<int> fds;
    std::vector<uint64_t> values, prevValues;
};

//
// CorePerfSensor monitors a single core using two PerfStatCounters (instructions and cache events).
//
class CorePerfSensor : public Sensor {
public:
    CorePerfSensor(std::string name, uint32_t coreId);
    virtual ~CorePerfSensor();
protected:
    void readFromSystem() override;
private:
    void handleReactivation();
    void handleShutDown();
    uint32_t coreId;
    std::unique_ptr<PerfStatCounters> instCtr, cacheCtr;
    bool shutDown;
    double coreBips, coreMpki;
};

//
// CPUPerfSensor monitors multiple cores and organizes perf events into four groups.
// The output vector is arranged as follows:
//
// Indices 0–3: Derived from Hardware Group 0 (4 events)
//   0. Perf_HW_CPUCycles
//   1. Perf_HW_BIPS = (instructions/time)
//   2. Perf_HW_BranchMisses
//   3. Perf_HW_BranchMissPerc = (branch misses / branch instructions)
//
// Indices 4–8: Derived from Hardware Group 1 (3 events)
//   4. Perf_HW_LlcRefs
//   5. Perf_HW_LlcMisses
//   6. Perf_HW_LlcMissRate = (LLC misses / LLC refs)
//   7. Perf_HW_BusCycles
//   8. Perf_HW_BusCyclesPerc = (Bus cycles / instructions)
//
// Indices 9–12: Raw software events from Software Group 2 (4 events)
//   9.  Perf_SW_CPUClock
//   10. Perf_SW_TaskClock
//   11. Perf_SW_PageFaults
//   12. Perf_SW_CPUMigrations
//
// Indices 13–15: Raw software events from Software Group 3 (3 events)
//   13. Perf_SW_ContextSwitches
//   14. Perf_SW_AlignmentFaults
//   15. Perf_SW_EmulationFaults
//
class CPUPerfSensor : public Sensor {
public:
    CPUPerfSensor(std::string name, std::vector<uint32_t> coreIds);
    virtual ~CPUPerfSensor();
protected:
    void readFromSystem() override;
private:
    void handleReactivation(uint32_t coreId);
    void handleShutDown(uint32_t coreId);
    std::vector<uint32_t> coreIds;
    std::vector<bool> shutDown; // per core
    // groupCounters[core][group] where group indices 0–3 are defined above.
    std::vector< std::vector<std::unique_ptr<PerfStatCounters>> > groupCounters;
};

class Dummy {
public:
    Vector readInputs();
    std::shared_ptr<InputPort> inp;
    Dummy(std::string name);
    Dummy(std::string name, std::initializer_list<std::string> portNames);
};

#endif /* SENSORS_H */
