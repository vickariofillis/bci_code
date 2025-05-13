/* 
 * File:   Controller.h
 * Author: Raghavendra Pradyumna Pothukuchi and Sweta Yamini Pothukuchi
 */

#ifndef CONTROLLER_H
#define CONTROLLER_H

#include "Abstractions.h"
#include "MathSupport.h"
#include <string>

/* Any controller to change inputs and meet targets can be derived from the general 
 * Controller class. Such controllers must re-define the computeNewInputs() function.
 */
class Controller {
public:
    Controller(std::string name, uint32_t smplInt = 1);
    std::string getName();
    void run();
    virtual void reset();
    std::shared_ptr<OutputPort> newInputVals, currOutputTargetVals;
    std::shared_ptr<InputPort> currInputVals, outputVals, outputTargetVals;
protected:
    virtual Vector computeNewInputs(bool run);
    std::string name;
    uint32_t samplingInterval, cycles;
};

//A Robust controller is a control theory controller. See README
class RobustController : public Controller {
public:
    RobustController(std::string name, std::string dirPath, std::string ctlFileName, uint32_t smplInt = 1);
    Vector computeNewInputs(bool run) override;
private:
    Matrix A, B, C, D;
    Vector state, deltaOutputs;

    Vector inputDenormalizeScales, outputNormalizeScales;
    //std::string dirPath = "/home/pothuku2/Research/visakha/code/Matlab/Controllers/";
};
#endif /* CONTROLLER_H */
