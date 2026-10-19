package io.github.mihok.sherpa_inference

import io.github.mihok.sherpa_inference.engine.PhaseTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class ExitDecoderTest {
  @Test fun classifiesTheReasonsTheHostCaresAbout() {
    assertEquals("nativeCrash", ExitDecoder.classify(ExitDecoder.REASON_CRASH_NATIVE, 6, null, true))
    assertEquals("lowMemory", ExitDecoder.classify(ExitDecoder.REASON_LOW_MEMORY, 9, null, true))
    assertEquals("likelyLowMemory", ExitDecoder.classify(ExitDecoder.REASON_SIGNALED, 9, null, false))
    assertEquals("signaled", ExitDecoder.classify(ExitDecoder.REASON_SIGNALED, 9, null, true))
    assertEquals("signaled", ExitDecoder.classify(ExitDecoder.REASON_SIGNALED, 15, null, false))
    assertEquals("memoryLimiter", ExitDecoder.classify(ExitDecoder.REASON_OTHER, 0, "MemoryLimiter:AnonSwap", true))
    assertEquals("crash", ExitDecoder.classify(ExitDecoder.REASON_CRASH, 0, null, true))
    assertEquals("anr", ExitDecoder.classify(ExitDecoder.REASON_ANR, 0, null, true))
    assertEquals("excessiveResourceUsage", ExitDecoder.classify(ExitDecoder.REASON_EXCESSIVE_RESOURCE_USAGE, 0, null, true))
    assertEquals("system", ExitDecoder.classify(ExitDecoder.REASON_PACKAGE_UPDATED, 0, null, true))
    assertEquals("unknown", ExitDecoder.classify(99, 0, null, true))
    assertEquals("CRASH_NATIVE", ExitDecoder.reasonName(5))
    assertEquals("FREEZER", ExitDecoder.reasonName(14))
  }

  // --- tombstone.proto fixtures, built with a tiny writer ------------------------------------------------

  private class W {
    val out = ByteArrayOutputStream()

    fun varint(v: Long): W {
      var x = v
      while (true) {
        if (x and 0x7FL.inv() == 0L) {
          out.write(x.toInt())
          return this
        }
        out.write(((x and 0x7F) or 0x80).toInt())
        x = x ushr 7
      }
    }

    fun tag(field: Int, wire: Int) = varint(((field shl 3) or wire).toLong())

    fun int(field: Int, v: Long) = tag(field, 0).varint(v)

    fun bytes(field: Int, b: ByteArray): W {
      tag(field, 2).varint(b.size.toLong())
      out.write(b)
      return this
    }

    fun str(field: Int, s: String) = bytes(field, s.toByteArray())

    fun msg(field: Int, m: W) = bytes(field, m.out.toByteArray())

    fun build(): ByteArray = out.toByteArray()
  }

  private fun frame(pc: Long, fn: String, off: Long, file: String) =
    W().int(1, pc).int(2, pc + 0x7000000000).str(4, fn).int(5, off).str(6, file).str(8, "0123abcd")

  private fun tombstone(): ByteArray {
    val crashing = W().int(1, 4242).str(2, "sherpa-engine-w")
      .msg(3, W().str(1, "x0").int(2, 0x1234)) // registers: dropped
      .msg(4, frame(0x4e8f0, "abort", 164, "/apex/com.android.runtime/lib64/bionic/libc.so"))
      .msg(4, frame(0x1a2b3c, "ggml_abort", 300, "/data/app/~~Q2x==/io.github.mihok.sherpa-Zz==/base.apk!/lib/arm64-v8a/libggml-base.so"))
      .msg(4, frame(0x99aa, "llama_decode", 12, "/data/app/~~Q2x==/io.github.mihok.sherpa-Zz==/lib/arm64/libllama.so"))
    val other = W().int(1, 1).str(2, "main").msg(4, frame(1, "epoll_wait", 4, "/system/lib64/libc.so"))
    return W()
      .int(1, 1) // arch ARM64
      .str(2, "google/husky/husky:17/AP4A/123:user/release-keys") // fingerprint: dropped
      .int(5, 4242).int(6, 4242).int(7, 10123)
      .str(9, "io.github.mihok.sherpa:inference") // command line: dropped
      .msg(10, W().int(1, 6).str(2, "SIGABRT").int(3, -1).str(4, "SI_TKILL"))
      .str(14, "/home/build/llama.cpp/ggml/src/ggml.c:1234: GGML_ASSERT(ne0 == ne1) failed")
      .msg(15, W().str(1, "null pointer dereference"))
      .msg(16, W().int(1, 1).msg(2, other))
      .msg(16, W().int(1, 4242).msg(2, crashing))
      .msg(18, W().str(1, "main").str(2, "secret user prompt in logcat")) // log buffers: dropped
      .build()
  }

  @Test fun protoTombstoneExcerptKeepsTheCrashAndDropsTheRest() {
    val s = TombstoneExcerpt.from(tombstone())!!
    assertTrue(s, s.startsWith("signal 6 (SIGABRT), code -1 (SI_TKILL)"))
    assertTrue(s, s.contains("abort: ggml.c:1234: GGML_ASSERT(ne0 == ne1) failed"))
    assertTrue(s, s.contains("cause: null pointer dereference"))
    assertTrue(s, s.contains("#00 libc.so (abort+164) pc 0x4e8f0"))
    assertTrue(s, s.contains("#01 libggml-base.so (ggml_abort+300)"))
    assertTrue(s, s.contains("#02 libllama.so (llama_decode+12)"))
    assertFalse("other threads", s.contains("epoll_wait"))
    for (secret in listOf("husky", "secret", "/data/app", "io.github.mihok.sherpa", "/home/build", "x0", "0123abcd")) {
      assertFalse("leaks $secret: $s", s.contains(secret))
    }
    assertTrue(s.length <= TombstoneExcerpt.MAX_CHARS)
  }

  @Test fun segvWithFaultAddress() {
    val t = W().int(6, 7)
      .msg(10, W().int(1, 11).str(2, "SIGSEGV").int(3, 1).str(4, "SEGV_MAPERR").int(8, 1).int(9, 0x10))
      .msg(16, W().int(1, 7).msg(2, W().int(1, 7).msg(4, frame(0x20, "ggml_vec_dot_q4_K_q8_K", 88, "/x/libggml-cpu-android_armv8.2_2.so"))))
      .build()
    val s = TombstoneExcerpt.from(t)!!
    assertTrue(s, s.startsWith("signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x10"))
    assertTrue(s, s.contains("libggml-cpu-android_armv8.2_2.so (ggml_vec_dot_q4_K_q8_K+88)"))
  }

  @Test fun textTombstone() {
    val text = """
      *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
      Build fingerprint: 'google/husky/husky:15/AP4A/1:user/release-keys'
      pid: 4242, tid: 4300, name: sherpa-engine  >>> io.github.mihok.sherpa:inference <<<
      signal 6 (SIGABRT), code -1 (SI_QUEUE), fault addr --------
      Abort message: '/src/ggml/ggml.c:99: GGML_ABORT("fatal error")'
          x0  0000000000000000  x1  00000000000010cc
      backtrace:
            #00 pc 000000000005c1f0  /apex/com.android.runtime/lib64/bionic/libc.so (abort+164) (BuildId: abc)
            #01 pc 0000000000012345  /data/app/~~x==/io.github.mihok.sherpa-y==/base.apk!libggml-base.so (offset 0x1000) (ggml_abort+40) (BuildId: def)

      memory near x1:
    """.trimIndent()
    val s = TombstoneExcerpt.from(text.toByteArray())!!
    assertTrue(s, s.startsWith("signal 6 (SIGABRT)"))
    assertTrue(s, s.contains("abort: ggml.c:99: GGML_ABORT(\"fatal error\")"))
    assertTrue(s, s.contains("#00 libc.so (abort+164) pc 0x5c1f0"))
    assertTrue(s, s.contains("#01 libggml-base.so"))
    assertFalse(s, s.contains("husky"))
    assertFalse(s, s.contains("x1  "))
  }

  @Test fun garbageAndHugeInputsAreBoundedAndNeverThrow() {
    assertNull(TombstoneExcerpt.from(ByteArray(0)))
    assertNull(TombstoneExcerpt.from(byteArrayOf(0x0a, 0x7f, 0x01)))
    val r = java.util.Random(1)
    repeat(200) {
      val b = ByteArray(r.nextInt(512)).also(r::nextBytes)
      TombstoneExcerpt.from(b) // must not throw
    }
    val long = W().msg(10, W().int(1, 6).str(2, "SIGABRT")).str(14, "x".repeat(100_000)).build()
    assertTrue(TombstoneExcerpt.from(long)!!.length <= TombstoneExcerpt.MAX_CHARS)
  }

  @Test fun processStateSummaryFormat() {
    val t = PhaseTracker {}
    assertEquals("""{"v":1,"p":"idle","h":"proc"}""", t.current())
    val tok = t.enter("generating", "a".repeat(200), 131072, "q8_0/q8_0\"}{")
    val s = t.current()
    assertTrue(s, s.toByteArray().size <= 128)
    assertTrue(s, s.startsWith("""{"v":1,"p":"generating","m":"aaaaaaaa"""))
    assertTrue(s, s.contains(""""c":131072,"k":"q8_0/q8_0","h":"proc"}"""))
    tok.close()
    assertEquals("""{"v":1,"p":"idle","h":"proc"}""", t.current())
    val (nCtx, kv) = PhaseTracker.sessionShape("""{"n_ctx_seq":1,"n_ctx" : 4352,"type_k":"q8_0","type_v":"f16"}""")
    assertEquals(4352L, nCtx)
    assertEquals("q8_0/f16", kv)
  }

  @Test fun onlyTransitionsArePublishedAndTheLatestActivePhaseWins() {
    val seen = ArrayList<String>()
    val t = PhaseTracker { seen.add(it) }
    val load = t.enter("loading", "m1")
    val gen = t.enter("generating", "m0", 2048, "f16/f16")
    load.close()
    load.close()
    gen.close()
    assertEquals(
      listOf(
        """{"v":1,"p":"loading","m":"m1","h":"proc"}""",
        """{"v":1,"p":"generating","m":"m0","c":2048,"k":"f16/f16","h":"proc"}""",
        """{"v":1,"p":"idle","h":"proc"}""",
      ),
      seen,
    )
  }
}
