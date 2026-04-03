#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <chrono>
#include <vector>

const std::vector<int> CPUS_TO_TRACK = {4, 6, 8, 10};

struct CPUStats {
    long long user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice;

    long long TotalTime() const {
        return user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice;
    }

    long long IdleTime() const {
        return idle + iowait;
    }
};

CPUStats ReadCPUStats(const std::string& cpu_line) {
    CPUStats stats;
    std::istringstream iss(cpu_line);
    std::string cpu;
    iss >> cpu;  // Skip the "cpu" or "cpu0", "cpu1", etc.
    iss >> stats.user >> stats.nice >> stats.system >> stats.idle >> stats.iowait 
        >> stats.irq >> stats.softirq >> stats.steal >> stats.guest >> stats.guest_nice;
    return stats;
}

void GetCPUStats(std::vector<CPUStats>& stats) {
    std::ifstream file("/proc/stat");
    std::string line;
    while (std::getline(file, line)) {
        if (line.compare(0, 3, "cpu") == 0  && isdigit(line[3])) {
            stats.push_back(ReadCPUStats(line));
        }
    }
}

void DumpCPUUsage(const std::vector<double>& usage, const std::string& filename, bool write_header) {
    std::ofstream file(filename, std::ios_base::app);

    if (write_header) {
        file << "timestamp";
        for (int cpu : CPUS_TO_TRACK) {
            file << ",cpu" << cpu;
        }
        file << std::endl;
    }

    auto curr_time = std::chrono::duration_cast<std::chrono::microseconds>( std::chrono::high_resolution_clock::now().time_since_epoch()).count();

    file << curr_time;
    for (int cpu : CPUS_TO_TRACK) {
        file << "," << usage[cpu];
    }
    file << std::endl;
}

void CalculateAndDumpCPUUsage(const std::string& filename, bool& first_dump) {
    std::vector<CPUStats> prev_stats;
    std::vector<CPUStats> curr_stats;

    GetCPUStats(prev_stats);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    GetCPUStats(curr_stats);

    std::vector<double> usage(prev_stats.size());

    for (size_t i = 0; i < prev_stats.size(); ++i) {
        long long prev_idle = prev_stats[i].IdleTime();
        long long curr_idle = curr_stats[i].IdleTime();
        long long prev_total = prev_stats[i].TotalTime();
        long long curr_total = curr_stats[i].TotalTime();

        long long total_diff = curr_total - prev_total;
        long long idle_diff = curr_idle - prev_idle;

        // Check if total_diff is zero to avoid division by zero
        if (total_diff == 0) {
            usage[i] = 0.0;
        } else {
            usage[i] = 100.0 * (1.0 - (double)idle_diff / total_diff);
        }
    }

    DumpCPUUsage(usage, filename, first_dump);
    first_dump = false;
}


int main(int argc, char * argv[]) {

    std::string filename;
    if (argc > 1) {
        filename = argv[1];
    } else {
        std::cout << "need a filename" << std::endl;
        return -1;
    }

    std::ofstream file(filename, std::ios::out | std::ios::trunc);
    file.close();

    bool first_dump = true;
    while (true) {
        CalculateAndDumpCPUUsage(filename, first_dump);
    }

    return 0;
}
