project(LnxTest)
cmake_minimum_required(VERSION 3.22)

add_executable(measure_cpu_util measure_cpu_util.cc)

add_executable(set_sched_ext set_sched_ext.c)

