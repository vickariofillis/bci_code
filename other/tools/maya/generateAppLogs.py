import numpy as np
import argparse
import os
import sys
import re

def dirPath(path):
    if os.path.isdir(path) is False:
        raise argparse.ArgumentTypeError(path+" is an invalid directory.")
    return path

def getArgs():
    parser = argparse.ArgumentParser(description='Generate reports from log files')
    parser.add_argument('--logdir', '-ld', help='Full path of log directory', type=dirPath,required=True)
    parser.add_argument('--repdir', '-rd', help='Full path of report directory', type=dirPath,required=True)
    parser.add_argument('--name', '-n', help='Name of run', required=True)
    parser.add_argument('--maxdur', '-m', help='Possible max duration (s) of an app (used to filter out bad runs)',type=float)
    cmdArgs = parser.parse_args()

    logFileName = os.path.join(cmdArgs.logdir, cmdArgs.name+"_log.txt")
    outFileName = os.path.join(cmdArgs.logdir,cmdArgs.name+ "_out.txt")

    mmrun = False
    if re.search('mm',cmdArgs.name):
        mmlogFileName = os.path.join(cmdArgs.logdir, cmdArgs.name+"_mmlog.txt")
        mmrun = True
    else:
        mmlogFileName =""

    if os.path.isfile(logFileName) is False or os.path.isfile(outFileName) is False:
        print(logFileName, " or ",outFileName, " do not exist")
        sys.exit()

    summaryFileName = os.path.join(cmdArgs.repdir,cmdArgs.name+ "_summary.txt")
    ext = "_"+cmdArgs.name+".txt"
    return logFileName,outFileName,cmdArgs.repdir,ext,summaryFileName,mmrun,mmlogFileName,cmdArgs.maxdur


def isValidRun(outFileName, maxdur):
    outFile = open(outFileName,"r")
    specBeginRun = False
    for line in outFile:
        if re.search("Running.*psc24",line):
            parts = line.split()
            fullName = parts[specAppNameLoc]
            parts = fullName.split(".")
            appName = parts[1]
            specBeginRun = True
        elif "Starting app" in line:
            parts = line.split()
            tBegin = float(parts[-1])
        elif specBeginRun == True and "Start command" in line:
            parts = line.split()
            tString = parts[-1]
            tBegin = float(tString[tString.find("(")+1:tString.find(")")])
        elif "Completed app" in line:
            parts = line.split()
            tEnd = float(parts[-1])
            if (tEnd - tBegin) > maxdur:
                outFile.close()
                return False
        elif specBeginRun == True and "Stop command" in line:
            specBeginRun = False
            parts = line.split()
            tString = parts[-1]
            tEnd = float(tString[tString.find("(") + 1:tString.find(")")])
            if (tEnd - tBegin) > maxdur:
                outFile.close()
                return False
    outFile.close()
    return True


if __name__ == "__main__":
    logFileName,outFileName,repDir,repExt,summaryFileName,mmrun,mmlogFileName,maxdur = getArgs()
    
    with open(logFileName) as logFile:
        headers = logFile.readline().strip().split()
    #print(headers)
    if 'CPUPower' in headers:
        cpuPowerLoc = headers.index('CPUPower')
    else:
        cpuPowerLoc = 31

    if 'DRAMPower' in headers:
        dramPowerLoc = headers.index('DRAMPower')
    else:
        dramPowerLoc = 32

    print("Processing ",logFileName)
    fullExpData = np.loadtxt(logFileName,skiprows=1)
    if mmrun:
        mmData = np.loadtxt(mmlogFileName)
    
    if maxdur is not None and isValidRun(outFileName,maxdur) == False:
        sys.exit("Run "+outFileName+" has apps that run far too long, more than "+maxdur+" s")


    outFile = open(outFileName, 'r')

    summaryFile = open(summaryFileName,'w')
    summaryFile.write("%35s %7s %8s %9s %10s\n"%("App", "Time(s)", "Power(W)", "Energy(J)", "ED"))

    numApps=0
    avgStats=np.zeros(4) #timeme,power,energy,ed
    appNameLoc = 2 #location number of the app name in the launch string from the out file
    specAppNameLoc = 1
    extractData = False
    specBeginRun = False
    appNames = []
    repCtr = []
    for line in outFile:
        if re.search("Running.*psc24",line):
            parts = line.split()
            fullName = parts[specAppNameLoc]
            parts = fullName.split(".")
            appName = parts[1]
            specBeginRun = True
        elif "Starting app" in line:
            parts = line.split()
            tBegin = float(parts[-1])
            appName = re.sub(r'/',r'_',parts[appNameLoc])
            if appName in appNames:
                idx = appNames.index(appName)
                appName = appName+str(repCtr[idx])
                repCtr[idx] = repCtr[idx]+1
            else:
                appNames.append(appName)
                repCtr.append(1)

        elif specBeginRun == True and "Start command" in line:
            parts = line.split()
            tString = parts[-1]
            tBegin = float(tString[tString.find("(")+1:tString.find(")")])
        elif "Completed app" in line:
            parts = line.split()
            tEnd = float(parts[-1])
            extractData = True
        elif specBeginRun == True and "Stop command" in line:
            parts = line.split()
            tString = parts[-1]
            tEnd = float(tString[tString.find("(") + 1:tString.find(")")])
            specBeginRun = False
            extractData = True

        if extractData == True:
            extractData = False
            appData = fullExpData[np.logical_and(fullExpData[:,0] >= tBegin,fullExpData[:,0] <= tEnd)]
            if mmrun:
                appmmData = mmData[np.logical_and(mmData[:,0] >= tBegin,mmData[:,0] <= tEnd)]
            appData=appData[appData.min(axis=1)>=0,:] #remove any samples with negative values
#            appData = fullExpData[np.logical_and(fullExpData['Time'] >= tBegin,fullExpData['Time'] <= tEnd)]
            appData=appData[np.argsort(appData[:,0])] #sort to fix any timestamps that are mis-located due to the fast sampling interval
            if appData.shape[0] > 30: #minimum 30 samples needed
                appReportName = os.path.join(repDir,appName + repExt)
                #print(' '.join(headers))
                with open(appReportName,'w') as repFile:
                    repFile.write(' '.join(headers)+'\n')
                    #repFile.write("\n")
                repFile = open(appReportName, "ab")
                np.savetxt(repFile,appData, fmt='%.3f'+(''.join([' %.2f']*(appData.shape[1]-1))))
                repFile.close()

                if mmrun:
                    appmmReportName = os.path.join(repDir,appName + "_mm" + repExt)
                    with open(appmmReportName,'w') as repFile:
                        repFile.write('Time Current CPUPower\n')
                    repFile = open(appmmReportName, "ab")
                    np.savetxt(repFile,appmmData, fmt=''.join([' %.2f']*appmmData.shape[1]))
                    repFile.close()
                    
                avgAppData = np.mean(appData,axis=0)
                totalTime = tEnd - tBegin
                averagePower = avgAppData[cpuPowerLoc]
                energy = averagePower * totalTime
                ed= totalTime * energy
                avgStats = avgStats+np.array([totalTime, averagePower, energy, ed])
                summaryFile.write("%35s %7.2f %8.2f %9.2f %10.2f\n" % (appName, totalTime, averagePower, energy, ed))
                numApps=numApps+1
    avgStats = avgStats/numApps
    summaryFile.write("%35s %7.2f %8.2f %9.2f %10.2f\n" % ("Average", avgStats[0],avgStats[1],avgStats[2],avgStats[3]))
    outFile.close()
    summaryFile.close()
