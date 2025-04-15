// Compile with:    g++ -std=c++11 -O2 cpu_stress.cpp -o cpu_stress
// Run with:        ./cpu_stress <num_threads> <duration_sec>

#include <iostream>
#include <thread>
#include <vector>
#include <chrono>
#include <cmath>

void stress_cpu(int duration_sec) {
    volatile double result = 0.0; // Use volatile to prevent optimization
    auto start = std::chrono::high_resolution_clock::now();
    while (true) {
        for (int i = 0; i < 1000000; ++i) {
            result += std::sin(i) * std::cos(i);
        }
        auto now = std::chrono::high_resolution_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - start).count();
        if (elapsed >= duration_sec) break;
    }
    std::cout << "Final result: " << result << "\n";
}

int main(int argc, char* argv[]) {
    if (argc != 3) {
        std::cerr << "Usage: " << argv[0] << " <num_threads> <duration_sec>\n";
        return 1;
    }

    int num_threads = std::stoi(argv[1]);
    int duration_sec = std::stoi(argv[2]);

    std::cout << "Stressing CPU with " << num_threads << " threads for " << duration_sec << " seconds.\n";

    std::vector<std::thread> threads;
    for (int i = 0; i < num_threads; ++i) {
        threads.emplace_back(stress_cpu, duration_sec);
    }

    for (auto& t : threads) t.join();

    std::cout << "CPU stress test complete.\n";
    return 0;
}
