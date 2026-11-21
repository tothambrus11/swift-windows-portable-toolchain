import CHelper

var buf = [CChar](repeating: 0, count: 64)
_ = chelper_format(&buf, buf.count, 42)
print(String(cString: buf), "ticks:", chelper_ticks(), "sqrt(2):", chelper_sqrt(2))
print("CTARGET OK")
