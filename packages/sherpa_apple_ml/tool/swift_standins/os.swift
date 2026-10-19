// STAND-IN for the Darwin `os` module, for type-checking on Linux only.
// <os/proc.h>: `extern size_t os_proc_available_memory(void);` (iOS 13+),
// imported into Swift as `func os_proc_available_memory() -> Int`.
public func os_proc_available_memory() -> Int { 0 }
