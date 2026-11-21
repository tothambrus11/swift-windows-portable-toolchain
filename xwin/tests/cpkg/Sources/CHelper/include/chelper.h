#pragma once
#include <stdint.h>
#include <stddef.h>
uint64_t chelper_ticks(void);
int chelper_format(char *buf, size_t len, int value);
double chelper_sqrt(double x);
