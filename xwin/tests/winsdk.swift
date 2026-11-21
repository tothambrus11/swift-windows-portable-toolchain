import WinSDK

let ticks = GetTickCount64()
var info = SYSTEM_INFO()
GetSystemInfo(&info)
var buf = [WCHAR](repeating: 0, count: Int(MAX_PATH))
let n = GetSystemDirectoryW(&buf, DWORD(buf.count))
let sysdir = String(decoding: buf[0..<Int(n)], as: UTF16.self)
print("GetTickCount64:", ticks, "CPUs:", info.dwNumberOfProcessors, "PID:", GetCurrentProcessId(), "sysdir:", sysdir)
print("WINSDK OK")
