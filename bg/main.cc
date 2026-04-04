#include <chrono>
#include <thread>
#include <iostream>
#include <opencv2/opencv.hpp>
#include <iostream>
#include <fstream>
#include<chrono>
#include <unistd.h>
#include <iostream>
#include <vector>
#include <string.h>
#include <sys/syscall.h>
#include <sys/resource.h>
#include <csignal>

#include "httplib.h"

#define N_ITER 10000000000

using namespace std;
using namespace chrono;

void cpu_spin() {
    int x =0;
    for (int i =0; i < N_ITER; i++) {
        x += i*x + 1;
    }
}

#define N_ROUNDS 80000
#define IMG_DIMS 160

#define SCHED_EXT 7

string img_resize() {
    
    string times;

    cv::Mat inputImage = cv::imread("1.jpg");

    if (inputImage.empty()) {
        cerr << "Error: Could not load image!" << endl;
        return "";
    }

    for (int i=0; i<N_ROUNDS;i++){
        cv::Mat resizedImage;
        cv::resize(inputImage, resizedImage, cv::Size(IMG_DIMS, IMG_DIMS), 0, 0, cv::INTER_LANCZOS4);

        cv::imwrite("resized_output.jpg", resizedImage);

        long current_time = std::chrono::duration_cast<std::chrono::microseconds>( high_resolution_clock::now().time_since_epoch()).count();
        times = times + to_string(current_time) + ",";
    }

    return times;
}

int main() {
    httplib::Server svr;

    struct sched_param param;
    param.sched_priority = 0;

    if (sched_setscheduler(0, SCHED_EXT, &param) == -1) {
        perror("sched_setscheduler");
        exit(1);
    }

    svr.Get("/spin", [](const httplib::Request&, httplib::Response& res) {
        cpu_spin();
        res.set_content(R"({"status": "ok", "v": "1"})", "application/json");
    });

    svr.Get("/img_resize", [](const httplib::Request&, httplib::Response& res) {
        string times = img_resize();
        string json = "{\"status\": \"ok\", \"times\": \"" + times + "\"}";
        res.set_content(json, "application/json");
    });

    svr.Get("/test", [](const httplib::Request&, httplib::Response& res) {
        res.set_content(R"({"status": "ok"})", "application/json");
    });

    std::cout << "Starting server on port 3001..." << std::endl;
    svr.listen("0.0.0.0", 3001);

    return 0;
}
