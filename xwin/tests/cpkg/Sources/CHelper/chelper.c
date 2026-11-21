#include "chelper.h"
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

uint64_t chelper_ticks(void) { return GetTickCount64(); }
int chelper_format(char *buf, size_t len, int value) {
  char *tmp = malloc(64);
  snprintf(tmp, 64, "C says %d", value);
  strncpy(buf, tmp, len);
  free(tmp);
  return (int)strlen(buf);
}
double chelper_sqrt(double x) { return sqrt(x); }
