import CxxDemo
import CxxStdlib

let v = makeVector(5)
var arr: [Int32] = []
for x in v { arr.append(x) }
print("vector:", arr, "sum:", sumVector(v), "size:", v.size())
print(String(greet()))
print("CXX OK")
