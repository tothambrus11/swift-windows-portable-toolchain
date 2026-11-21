#pragma once
#include <vector>
#include <string>
#include <numeric>

inline std::vector<int> makeVector(int n) {
  std::vector<int> v(n);
  std::iota(v.begin(), v.end(), 1);
  return v;
}
inline int sumVector(const std::vector<int> &v) { return std::accumulate(v.begin(), v.end(), 0); }
inline std::string greet() { return std::string("hello from C++"); }
