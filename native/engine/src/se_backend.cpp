// Process-wide backend initialisation (the engine's only global state besides thread-local errors),
// logging, crash breadcrumbs, and the system-info report.
#include "se_internal.h"

#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "log.h"

#include <cstdarg>
#include <cstdio>
#include <fstream>
#include <thread>

#if defined(__ANDROID__)
#include <android/log.h>
#endif
#if defined(__linux__) || defined(__ANDROID__)
#include <fcntl.h>
#include <sys/auxv.h>
#include <sys/prctl.h>
#include <unistd.h>
#endif
#if defined(__APPLE__)
#include <fcntl.h>
#include <sys/sysctl.h>
#include <unistd.h>
#endif
#if defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
#endif

namespace se {

namespace {

// Written exactly once inside std::call_once, read-only afterwards.
struct BackendState {
  int32_t     log_level = SE_LOG_WARN;
  se_log_cb   log_cb = nullptr;
  void *      log_user = nullptr;
  std::string crash_path;
  std::string cpu_variant;    // Android DL: loaded libggml-cpu-<variant>.so
  std::string init_report;    // what the loader tried (for system info)
};

std::once_flag g_backend_once;  // the backend-init once flag
BackendState   g_state;         // immutable after g_backend_once

int32_t map_ggml_level(ggml_log_level l) {
  switch (l) {
    case GGML_LOG_LEVEL_DEBUG: return SE_LOG_DEBUG;
    case GGML_LOG_LEVEL_INFO:  return SE_LOG_INFO;
    case GGML_LOG_LEVEL_WARN:  return SE_LOG_WARN;
    case GGML_LOG_LEVEL_ERROR: return SE_LOG_ERROR;
    default:                   return -1;  // NONE / CONT: continuation of the previous line
  }
}

void sink(int32_t level, const char * msg) {
  if (level < g_state.log_level) {
    return;
  }
  if (g_state.log_cb) {
    g_state.log_cb(level, msg, g_state.log_user);
    return;
  }
#if defined(__ANDROID__)
  const int prio = level >= SE_LOG_ERROR ? ANDROID_LOG_ERROR : level >= SE_LOG_WARN ? ANDROID_LOG_WARN
                 : level >= SE_LOG_INFO ? ANDROID_LOG_INFO : ANDROID_LOG_DEBUG;
  __android_log_write(prio, "sherpa_engine", msg);
#else
  std::fputs(msg, stderr);
#endif
}

thread_local std::string * t_log_tap = nullptr;

// llama/ggml log callback. CONT lines continue the previous message, so remember its level per thread.
void llama_log_bridge(ggml_log_level level, const char * text, void *) {
  if (t_log_tap && text) t_log_tap->append(text);
  thread_local int32_t last = SE_LOG_INFO;
  int32_t l = map_ggml_level(level);
  if (l < 0) {
    l = last;
  } else {
    last = l;
  }
  sink(l, text ? text : "");
}

// Called by ggml right before abort() (ggml/src/ggml.c:253-273). Only async-signal-safe-ish calls.
void crash_breadcrumb(const char * message) {
#if defined(__linux__) || defined(__ANDROID__) || defined(__APPLE__)
  if (!g_state.crash_path.empty()) {
    const int fd = ::open(g_state.crash_path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
      const char hdr[] = "sherpa_engine fatal ggml error: ";
      (void) !::write(fd, hdr, sizeof(hdr) - 1);
      if (message) (void) !::write(fd, message, std::strlen(message));
      (void) !::write(fd, "\n", 1);
      ::close(fd);
    }
  }
#endif
  sink(SE_LOG_ERROR, message ? message : "ggml abort");
}

void load_backends(const char * backend_dir, std::string & report) {
  if (backend_dir && *backend_dir) {
    ggml_backend_load_all_from_path(backend_dir);
    report = std::string("ggml_backend_load_all_from_path(") + backend_dir + ")";
    return;
  }
#if SE_BACKEND_DL && SE_CPU_VARIANT_COUNT > 0
#  if defined(__ANDROID__)
  // R05 §4.3: upstream's ggml_backend_load_best() enumerates a directory, but AGP stores JNI libs
  // uncompressed inside the APK by default (minSdk >= 23), so nativeLibraryDir is empty and nothing is
  // found. dlopen() of a *bare* file name is resolved by bionic in the app's linker namespace, APK
  // included (the mechanism System.loadLibrary uses). Variants are declared in ascending capability
  // order, so walk them backwards and keep the first one whose ggml_backend_score() is non-zero
  // (ggml_backend_load rejects score 0, ggml-backend-reg.cpp:229-235).
  static const char * const k_variants[] = SE_CPU_VARIANTS;
  for (int i = SE_CPU_VARIANT_COUNT - 1; i >= 0; --i) {
    const std::string lib = std::string("libggml-cpu-") + k_variants[i] + ".so";
    report += lib;
    if (ggml_backend_load(lib.c_str()) != nullptr) {
      g_state.cpu_variant = k_variants[i];
      report += " -> loaded";
      return;
    }
    report += " -> unsupported; ";
  }
  if (ggml_backend_load("libggml-cpu.so") != nullptr) {
    g_state.cpu_variant = "generic";
    report += "libggml-cpu.so -> loaded";
    return;
  }
  report += "no CPU backend could be loaded";
  return;
#  endif
#endif
  // Static builds (iOS, host) registered their backends at link time; this is then a no-op. Desktop DL
  // builds scan the executable's directory.
  ggml_backend_load_all();
  report = "ggml_backend_load_all()";
}

void do_init(const se_init_params & p) {
  g_state.log_level = p.log_level <= 0 ? SE_LOG_WARN : p.log_level;
  g_state.log_cb    = p.log_cb;
  g_state.log_user  = p.log_user;
  if (p.crash_breadcrumb_path) g_state.crash_path = p.crash_breadcrumb_path;

  // llama_log_set is global and not thread-safe (llama.h:1663-1667): set it once, here.
  llama_log_set(llama_log_bridge, nullptr);
#if SE_HAVE_MTMD
  // mtmd and clip log through their own logger (stderr by default, every image at INFO).
  mtmd_helper_log_set(llama_log_bridge, nullptr);
#endif
  ggml_set_abort_callback(crash_breadcrumb);
  // common/ logs through its own singleton (worker thread, stdout). Keep it to warnings and errors.
  common_log_set_verbosity_thold(g_state.log_level <= SE_LOG_INFO ? LOG_LEVEL_INFO : LOG_LEVEL_WARN);

  // In GGML_BACKEND_DL builds nothing is registered statically, so backends must be loaded before
  // llama_backend_init() (which only calls ggml_backend_load_all() when the registry is empty).
  load_backends(p.backend_dir, g_state.init_report);
  llama_backend_init();
}

}  // namespace

void ensure_backend() {
  std::call_once(g_backend_once, [] {
    se_init_params p;
    se_init_params_init(&p);
    do_init(p);
  });
}

void log(int32_t level, const char * fmt, ...) {
  if (level < g_state.log_level) return;
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  sink(level, buf);
}

std::string loaded_cpu_variant() {
  return g_state.cpu_variant;
}

LogTap::LogTap(std::string * sink) : prev(t_log_tap) {
  t_log_tap = sink;
}

LogTap::~LogTap() {
  t_log_tap = prev;
}

int32_t resolved_flash_attn(int32_t requested, const std::string & log_text) {
  if (requested == 0 || requested == 1) return requested;
  // flash_attn_type = AUTO is resolved by a graph-reserve probe inside llama_context
  // (src/llama-context.cpp:507-558) and only reported through the log ("Flash Attention enabled" /
  // "Flash Attention not supported, set to disabled"). A quantized V cache forces it on (:3840-3848).
  if (log_text.find("Flash Attention not supported") != std::string::npos) return 0;
  if (log_text.find("Flash Attention enabled") != std::string::npos) return 1;
  if (log_text.find("enabling flash_attn since it is required") != std::string::npos) return 1;
  return -1;  // unknown (upstream wording changed); state files then rely on llama's own V-layout check
}

std::string backend_label() {
  std::string gpus;
  for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
    ggml_backend_dev_t d = ggml_backend_dev_get(i);
    const auto t = ggml_backend_dev_type(d);
    if (t == GGML_BACKEND_DEVICE_TYPE_GPU || t == GGML_BACKEND_DEVICE_TYPE_IGPU) {
      if (!gpus.empty()) gpus += "+";
      gpus += ggml_backend_dev_name(d);
    }
  }
  std::string cpu = "CPU";
  if (!g_state.cpu_variant.empty()) cpu += " (" + g_state.cpu_variant + ")";
  return gpus.empty() ? cpu : gpus + "+" + cpu;
}

namespace {

#if defined(__linux__) || defined(__ANDROID__)
// Performance cores: CPUs whose cpuinfo_max_freq is within 80% of the fastest. On big.LITTLE phones this
// counts prime + big cores, which is what decode wants (little cores slow the whole graph down).
int32_t perf_cores_from_cpufreq(int32_t n_cpus) {
  std::vector<long> f;
  for (int32_t i = 0; i < n_cpus; ++i) {
    std::ifstream in("/sys/devices/system/cpu/cpu" + std::to_string(i) + "/cpufreq/cpuinfo_max_freq");
    long v = 0;
    if (in >> v) f.push_back(v);
  }
  if (f.empty()) return 0;
  const long mx = *std::max_element(f.begin(), f.end());
  int32_t n = 0;
  for (long v : f) n += v * 10 >= mx * 8;
  return n;
}
#endif

int32_t n_cpus() {
#if defined(__linux__) || defined(__ANDROID__) || defined(__APPLE__)
  const long n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n > 0) return (int32_t) n;
#endif
  const unsigned n2 = std::thread::hardware_concurrency();
  return n2 ? (int32_t) n2 : 1;
}

int32_t perf_cores() {
#if defined(__APPLE__)
  int v = 0;
  size_t len = sizeof v;
  if (sysctlbyname("hw.perflevel0.physicalcpu", &v, &len, nullptr, 0) == 0 && v > 0) return v;
#endif
#if defined(__linux__) || defined(__ANDROID__)
  const int32_t n = perf_cores_from_cpufreq(n_cpus());
  if (n > 0) return n;
#endif
  return common_cpu_get_num_physical_cores();
}

// CPU features detected on *this* device at runtime. ggml_cpu_has_dotprod() & co. are compile-time
// checks of whichever CPU backend is loaded (ggml/src/ggml-cpu/ggml-cpu.c:3811-3849, R04 §18), so they
// cannot tell the Dart side what the hardware could do.
common_json runtime_cpu_features() {
  common_json f = common_json::object();
#if (defined(__linux__) || defined(__ANDROID__)) && defined(__aarch64__)
  const unsigned long hw  = getauxval(AT_HWCAP);
  const unsigned long hw2 = getauxval(AT_HWCAP2);
  // Bit positions from the arm64 Linux UAPI (arch/arm64/include/uapi/asm/hwcap.h), spelled out so that
  // older NDK headers do not hide newer bits.
  f["neon"]    = (bool) (hw & (1ul << 1));    // HWCAP_ASIMD
  f["fp16"]    = (bool) (hw & (1ul << 10));   // HWCAP_ASIMDHP
  f["dotprod"] = (bool) (hw & (1ul << 20));   // HWCAP_ASIMDDP
  f["sve"]     = (bool) (hw & (1ul << 22));   // HWCAP_SVE
  f["sve2"]    = (bool) (hw2 & (1ul << 1));   // HWCAP2_SVE2
  f["i8mm"]    = (bool) (hw2 & (1ul << 13));  // HWCAP2_I8MM
  f["bf16"]    = (bool) (hw2 & (1ul << 14));  // HWCAP2_BF16
  f["sme"]     = (bool) (hw2 & (1ul << 23));  // HWCAP2_SME
  f["sme2"]    = (bool) (hw2 & (1ul << 37));  // HWCAP2_SME2
  int vl = 0;
#  ifdef PR_SVE_GET_VL
  if (hw & (1ul << 22)) {
    const int r = prctl(PR_SVE_GET_VL);
    if (r >= 0) vl = r & 0xffff;  // PR_SVE_VL_LEN_MASK
  }
#  endif
  f["sve_vector_bytes"] = vl;
#elif defined(__APPLE__) && defined(__aarch64__)
  auto has = [](const char * name) {
    int v = 0;
    size_t len = sizeof v;
    return sysctlbyname(name, &v, &len, nullptr, 0) == 0 && v != 0;
  };
  f["neon"]    = has("hw.optional.AdvSIMD");
  f["fp16"]    = has("hw.optional.arm.FEAT_FP16");
  f["dotprod"] = has("hw.optional.arm.FEAT_DotProd");
  f["i8mm"]    = has("hw.optional.arm.FEAT_I8MM");
  f["bf16"]    = has("hw.optional.arm.FEAT_BF16");
  f["sme"]     = has("hw.optional.arm.FEAT_SME");
  f["sme2"]    = has("hw.optional.arm.FEAT_SME2");
  f["sve"]     = false;
  f["sve2"]    = false;
#elif defined(__x86_64__) || defined(__i386__)
  __builtin_cpu_init();
  f["sse4_2"]     = (bool) __builtin_cpu_supports("sse4.2");
  f["avx"]        = (bool) __builtin_cpu_supports("avx");
  f["avx2"]       = (bool) __builtin_cpu_supports("avx2");
  f["fma"]        = (bool) __builtin_cpu_supports("fma");
  f["avx512f"]    = (bool) __builtin_cpu_supports("avx512f");
  f["avx512vnni"] = (bool) __builtin_cpu_supports("avx512vnni");
  unsigned a = 0, b = 0, c = 0, d = 0;
  bool amx_int8 = false, avx_vnni = false;
  if (__get_cpuid_count(7, 0, &a, &b, &c, &d)) amx_int8 = (d >> 25) & 1;
  if (__get_cpuid_count(7, 1, &a, &b, &c, &d)) avx_vnni = (a >> 4) & 1;
  f["amx_int8"] = amx_int8;
  f["avx_vnni"] = avx_vnni;
#endif
  return f;
}

std::string dev_type_name(enum ggml_backend_dev_type t) {
  switch (t) {
    case GGML_BACKEND_DEVICE_TYPE_CPU:   return "cpu";
    case GGML_BACKEND_DEVICE_TYPE_GPU:   return "gpu";
    case GGML_BACKEND_DEVICE_TYPE_IGPU:  return "igpu";
    case GGML_BACKEND_DEVICE_TYPE_ACCEL: return "accel";
    default:                             return "other";
  }
}

}  // namespace

int32_t default_thread_count() {
  int32_t n = perf_cores();
  if (n <= 0) n = 4;
  return std::max(1, std::min(n, 8));
}

std::string system_info_json() {
  common_json j = common_json::object();
  j["engine"]       = se_version_string();
  j["abi_version"]  = (int) SE_ABI_VERSION;
  j["llama_commit"] = SE_LLAMA_COMMIT;
  j["ggml_version"] = ggml_version();
  j["backend_dl"]   = (bool) SE_BACKEND_DL;
  j["abi_minor"]    = (int) SE_ABI_MINOR;
  j["mtmd"]         = (bool) SE_HAVE_MTMD;
  // Image content parts are accepted (with a vision projector loaded): ABI 1.1 + an mtmd build.
  j["image_input"]  = (bool) SE_HAVE_MTMD;
  j["backend_init"] = g_state.init_report;
  j["cpu_variant"]  = g_state.cpu_variant;

  common_json regs = common_json::array();
  common_json cpu_backend_features = common_json::object();
  for (size_t i = 0; i < ggml_backend_reg_count(); ++i) {
    ggml_backend_reg_t reg = ggml_backend_reg_get(i);
    common_json r = common_json::object();
    r["name"]      = ggml_backend_reg_name(reg);
    r["n_devices"] = (int64_t) ggml_backend_reg_dev_count(reg);
    regs.push_back(r);
    auto get_features = (ggml_backend_get_features_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_get_features");
    if (get_features && std::string(ggml_backend_reg_name(reg)) == "CPU") {
      for (ggml_backend_feature * ft = get_features(reg); ft && ft->name; ++ft) {
        cpu_backend_features[ft->name] = ft->value ? ft->value : "";
      }
    }
  }
  j["backends"] = regs;
  // Compile-time feature set of the loaded CPU backend variant (what ggml kernels may use).
  j["cpu_backend_features"] = cpu_backend_features;

  common_json devs = common_json::array();
  for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
    ggml_backend_dev_t d = ggml_backend_dev_get(i);
    size_t free_b = 0, total_b = 0;
    ggml_backend_dev_memory(d, &free_b, &total_b);
    common_json o = common_json::object();
    o["name"]        = ggml_backend_dev_name(d);
    o["description"] = ggml_backend_dev_description(d);
    o["type"]        = dev_type_name(ggml_backend_dev_type(d));
    // For the CPU device this is physical RAM, not an app budget (R04 §2): plan with OS memory APIs.
    o["memory_free"]  = (uint64_t) free_b;
    o["memory_total"] = (uint64_t) total_b;
    devs.push_back(o);
  }
  j["devices"] = devs;

  common_json cpu = common_json::object();
#if defined(__aarch64__)
  cpu["arch"] = "arm64";
#elif defined(__x86_64__)
  cpu["arch"] = "x86_64";
#else
  cpu["arch"] = "other";
#endif
  cpu["logical_cores"]        = n_cpus();
  cpu["physical_cores"]       = common_cpu_get_num_physical_cores();
  cpu["performance_cores"]    = perf_cores();
  cpu["default_threads"]      = default_thread_count();
  cpu["features"]             = runtime_cpu_features();
  j["cpu"] = cpu;

  common_json sup = common_json::object();
  sup["mmap"]        = llama_supports_mmap();
  sup["mlock"]       = llama_supports_mlock();
  sup["gpu_offload"] = llama_supports_gpu_offload();
  j["supports"] = sup;
  return j.dump_safe();  // dump() throws on invalid UTF-8 (common/json.h); never fail a report on it
}

}  // namespace se

extern "C" {

SE_API se_status se_backend_init(const se_init_params * p) {
  return se::guard(__func__, [&]() -> se_status {
    const se_init_params ip = se::read_params(p, se_init_params_init);
    bool ran = false;
    std::call_once(se::g_backend_once, [&] {
      ran = true;
      se::do_init(ip);
    });
    if (!ran) {
      se::log(SE_LOG_DEBUG, "se_backend_init: already initialised, parameters ignored\n");
    }
    return SE_OK;
  });
}

SE_API int32_t se_system_info_json(char * buf, int32_t cap) {
  return se::guard(__func__, [&]() -> int32_t {
    se::ensure_backend();
    return se::copy_out(se::system_info_json(), buf, cap);
  });
}

}  // extern "C"
