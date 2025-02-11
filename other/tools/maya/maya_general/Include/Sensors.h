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

// If a dedicated L2 cache counter is not available, you can define it here.
// (For now, we are omitting L2 from our cache measurements.)
#ifndef PERF_COUNT_HW_CACHE_L2
#define PERF_COUNT_HW_CACHE_L2 7
#endif

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
    Vector values, prevValues; // current and previous sensor values
    uint32_t width; // number of values (default is 1)
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
// CorePerfSensor monitors a single core using two PerfStatCounters (one for instructions and one for cache events).
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
// CPUPerfSensor monitors multiple cores. Its output vector is arranged as follows:
//
// Indices 0–3: Derived from Hardware Group 0 (4 events)
//   0. Perf_HW_CPUCycles
//   1. Perf_HW_BIPS (instructions per time)
//   2. Perf_HW_BranchMisses
//   3. Perf_HW_BranchMissPerc (branch miss percentage)
//
// Indices 4–8: Derived from Hardware Group 1 (3 events)
//   4. Perf_HW_LlcRefs
//   5. Perf_HW_LlcMisses
//   6. Perf_HW_LlcMissRate (LLC misses / LLC refs)
//   7. Perf_HW_BusCycles
//   8. Perf_HW_BusCyclesPerc (Bus cycles / instructions)
//
// Indices 9–12: Software Group 2 (4 events)
//   9.  Perf_SW_CPUClock
//   10. Perf_SW_TaskClock
//   11. Perf_SW_PageFaults
//   12. Perf_SW_CPUMigrations
//
// Indices 13–15: Software Group 3 (3 events)
//   13. Perf_SW_ContextSwitches
//   14. Perf_SW_AlignmentFaults
//   15. Perf_SW_EmulationFaults
//
// Indices 16–51: New cache events for 6 cache types (6 metrics per cache).
// The order for caches is: L1D, L1I, LL, DTLB, ITLB, BPU.
// For each cache the metrics are (in order):
//   Perf_<cache>_Reads, Perf_<cache>_Writes, Perf_<cache>_Prefetches,
//   Perf_<cache>_Accesses, Perf_<cache>_Misses, Perf_<cache>_MissRate
//
struct CachePerfGroups {
    std::unique_ptr<PerfStatCounters> ops;     // counts: READ, WRITE, PREFETCH (using RESULT_ACCESS)
    std::unique_ptr<PerfStatCounters> results; // counts: (for op READ) ACCESS and MISS
};

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
    // Existing groups: 0–3 (hardware and software events)
    std::vector< std::vector<std::unique_ptr<PerfStatCounters>> > groupCounters;
    // New cache groups: for each core, for each of 6 cache types
    std::vector< std::vector<CachePerfGroups> > cacheCounters;
};

class Dummy {
public:
    Vector readInputs();
    std::shared_ptr<InputPort> inp;
    Dummy(std::string name);
    Dummy(std::string name, std::initializer_list<std::string> portNames);
};

#endif /* SENSORS_H */
