package io.github.mihok.sherpa_platform

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CpuInfoParserTest {
  // Abridged arm64 /proc/cpuinfo from a Snapdragon 8 Gen 2-class device:
  // little cores lack sve2/i8mm here only to prove the union is taken.
  private val cpuinfo = """
    processor	: 0
    BogoMIPS	: 38.40
    Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp
    CPU implementer	: 0x41
    CPU part	: 0xd46

    processor	: 7
    BogoMIPS	: 38.40
    Features	: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm jscvt fcma lrcpc dcpop sha3 sm3 sm4 asimddp sha512 sve asimdfhm dit uscat ilrcpc flagm ssbs sb paca pacg dcpodp sve2 sveaes svepmull svebitperm svesha3 svesm4 flagm2 frint svei8mm svebf16 i8mm bf16 dgh bti
    CPU part	: 0xd4e
  """.trimIndent()

  @Test fun mapsKernelNamesAndTakesTheUnion() {
    assertEquals(listOf("bf16", "dotprod", "fp16", "i8mm", "sve", "sve2"), CpuInfoParser.features(cpuinfo))
  }

  @Test fun smeAndSme2() {
    assertEquals(listOf("sme", "sme2"), CpuInfoParser.features("Features\t: fp asimd sme sme2 smei8i32"))
  }

  @Test fun ignoresOtherKeysAndEmptyInput() {
    assertEquals(emptyList<String>(), CpuInfoParser.features(""))
    assertEquals(emptyList<String>(), CpuInfoParser.features("Hardware\t: Qualcomm i8mm sve\nflags : asimddp"))
  }
}

class CpuTopologyTest {
  @Test fun parsesSysfsRanges() {
    assertEquals((0..7).toList(), CpuTopology.parseRange("0-7\n"))
    assertEquals(listOf(0, 1, 2, 3, 5, 7, 8), CpuTopology.parseRange("0-3,5,7-8"))
    assertEquals(listOf(0), CpuTopology.parseRange("0"))
    assertEquals(emptyList<Int>(), CpuTopology.parseRange("garbage"))
    assertEquals(emptyList<Int>(), CpuTopology.parseRange("5-2"))
  }

  @Test fun bigCoresExcludeTheLowestClusterByFrequency() {
    // 3 × A510 @ 2.0, 4 × A715/A710 @ 2.8, 1 × X3 @ 3.2 (kHz).
    val freq = listOf(2016000L, 2016000, 2016000, 2803200, 2803200, 2803200, 2803200, 3187200)
    assertEquals(listOf(3, 4, 5, 6, 7), CpuTopology.bigCores(emptyList(), freq))
  }

  @Test fun capacityWinsWhenEveryCoreReportsIt() {
    // Same frequency for cores 2 and 3, but the scheduler ranks 3 higher.
    val freq = listOf(1800000L, 1800000, 2400000, 2400000)
    val capacity = listOf(325L, 325, 825, 1024)
    assertEquals(listOf(2, 3), CpuTopology.bigCores(capacity, freq))
  }

  @Test fun partialCapacityFallsBackToFrequency() {
    val freq = listOf(1800000L, 2400000)
    assertEquals(listOf(1), CpuTopology.bigCores(listOf(0L, 1024), freq))
  }

  @Test fun homogeneousCpuIsAllBigAndUnknownCoresAreSkipped() {
    assertEquals(listOf(0, 1, 2, 3), CpuTopology.bigCores(emptyList(), listOf(2000000L, 2000000, 2000000, 2000000)))
    assertEquals(listOf(1, 2), CpuTopology.bigCores(emptyList(), listOf(0L, 2000000, 2000000)))
    assertEquals(emptyList<Int>(), CpuTopology.bigCores(emptyList(), listOf(0L, 0)))
    assertEquals(emptyList<Int>(), CpuTopology.bigCores(emptyList(), emptyList()))
  }
}

class ProcStatusParserTest {
  private val status = """
    Name:	sherpa
    State:	S (sleeping)
    VmRSS:	  812345 kB
    RssAnon:	  400000 kB
    RssFile:	  410000 kB
    VmSwap:	   20000 kB
    Threads:	42
  """.trimIndent()

  @Test fun readsKilobyteFields() {
    val f = ProcStatusParser.kilobytes(status)
    assertEquals(812345L * 1024, ProcStatusParser.rssBytes(f))
    // Limiter metric: anonymous RSS + swap, not file-backed pages.
    assertEquals(420000L * 1024, ProcStatusParser.anonSwapBytes(f))
    assertNull(f["Threads"])
  }

  @Test fun missingFieldsAreNull() {
    val f = ProcStatusParser.kilobytes("VmRSS: 10 kB")
    assertNull(ProcStatusParser.anonSwapBytes(f))
    assertEquals(10L * 1024, ProcStatusParser.rssBytes(f))
  }

  @Test fun swapIsOptional() {
    assertEquals(5L * 1024, ProcStatusParser.anonSwapBytes(ProcStatusParser.kilobytes("RssAnon: 5 kB")))
  }
}

class ExitClassifierTest {
  private fun c(reason: Int, status: Int = 0, desc: String? = null, lmk: Boolean = true) =
    ExitClassifier.classify(reason, status, desc, lmk)

  @Test fun memoryLimiterIsReportedAsOtherWithADescription() {
    assertEquals("memoryLimiter", c(ExitClassifier.REASON_OTHER, desc = "MemoryLimiter:AnonSwap"))
    // Robust to a future reason code carrying the same marker.
    assertEquals("memoryLimiter", c(ExitClassifier.REASON_SIGNALED, 9, "killed by MemoryLimiter"))
    assertEquals("other", c(ExitClassifier.REASON_OTHER, desc = "something else"))
  }

  @Test fun lowMemoryAndTheSigkillHeuristic() {
    assertEquals("lowMemory", c(ExitClassifier.REASON_LOW_MEMORY))
    assertEquals("likelyLowMemory", c(ExitClassifier.REASON_SIGNALED, status = 9, lmk = false))
    // With LMK reporting supported, a SIGKILL is not an LMK kill.
    assertEquals("signaled", c(ExitClassifier.REASON_SIGNALED, status = 9, lmk = true))
    assertEquals("signaled", c(ExitClassifier.REASON_SIGNALED, status = 15, lmk = false))
  }

  @Test fun otherReasons() {
    assertEquals("crash", c(ExitClassifier.REASON_CRASH))
    assertEquals("nativeCrash", c(ExitClassifier.REASON_CRASH_NATIVE))
    assertEquals("anr", c(ExitClassifier.REASON_ANR))
    assertEquals("userStopped", c(ExitClassifier.REASON_USER_REQUESTED))
    assertEquals("userStopped", c(ExitClassifier.REASON_USER_STOPPED))
    assertEquals("exitSelf", c(ExitClassifier.REASON_EXIT_SELF))
    assertEquals("system", c(ExitClassifier.REASON_PACKAGE_UPDATED))
    assertEquals("excessiveResourceUsage", c(ExitClassifier.REASON_EXCESSIVE_RESOURCE_USAGE))
    assertEquals("freezer", c(ExitClassifier.REASON_FREEZER))
    assertEquals("unknown", c(ExitClassifier.REASON_UNKNOWN))
    assertEquals("unknown", c(99))
  }

  @Test fun reasonNames() {
    assertEquals("LOW_MEMORY", ExitClassifier.reasonName(3))
    assertEquals("OTHER", ExitClassifier.reasonName(13))
    assertEquals("UNKNOWN", ExitClassifier.reasonName(1234))
  }
}

class Utf8Test {
  @Test fun keepsShortInput() {
    val b = "phase=load".toByteArray()
    assertArrayEquals(b, Utf8.truncate(b, 128))
  }

  @Test fun neverSplitsAMultiByteCharacter() {
    // "é" is 2 bytes (C3 A9): cutting at 4 would leave a dangling C3.
    val b = "abcé".toByteArray(Charsets.UTF_8)
    assertEquals(5, b.size)
    assertEquals("abc", String(Utf8.truncate(b, 4), Charsets.UTF_8))
    assertEquals("abcé", String(Utf8.truncate(b, 5), Charsets.UTF_8))
    // 4-byte emoji.
    val e = "a😀".toByteArray(Charsets.UTF_8)
    assertEquals("a", String(Utf8.truncate(e, 4), Charsets.UTF_8))
  }
}
