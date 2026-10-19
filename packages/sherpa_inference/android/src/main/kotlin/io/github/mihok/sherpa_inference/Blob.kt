package io.github.mihok.sherpa_inference

import android.os.Parcel
import android.os.Parcelable
import android.os.SharedMemory
import android.system.OsConstants

/**
 * One [Wire] message in a Binder transaction: inline bytes up to [Wire.INLINE_MAX], otherwise a
 * read-only [SharedMemory] region (the parcel carries only its fd). The sender closes its copy right after
 * the transaction (the driver holds its own file reference); the receiver closes after [bytes].
 */
class Blob private constructor(private val inline: ByteArray?, private var shm: SharedMemory?, private val length: Int) :
  Parcelable {
  /** The payload; maps and releases the shared region on first use. */
  fun bytes(): ByteArray {
    inline?.let { return it }
    val region = shm ?: error("blob already consumed")
    try {
      val map = region.mapReadOnly()
      try {
        val out = ByteArray(length)
        map.get(out)
        return out
      } finally {
        SharedMemory.unmap(map)
      }
    } finally {
      close()
    }
  }

  fun close() {
    shm?.close()
    shm = null
  }

  override fun describeContents(): Int = if (shm != null) Parcelable.CONTENTS_FILE_DESCRIPTOR else 0

  override fun writeToParcel(dest: Parcel, flags: Int) {
    if (inline != null) {
      dest.writeInt(MODE_INLINE)
      dest.writeByteArray(inline)
    } else {
      dest.writeInt(MODE_SHARED)
      dest.writeInt(length)
      (shm ?: error("blob already consumed")).writeToParcel(dest, flags)
    }
  }

  companion object {
    private const val MODE_INLINE = 0
    private const val MODE_SHARED = 1

    fun of(bytes: ByteArray): Blob {
      if (!Wire.useSharedMemory(bytes.size)) return Blob(bytes, null, bytes.size)
      val region = SharedMemory.create("sherpa-inference-ipc", bytes.size)
      try {
        val map = region.mapReadWrite()
        try {
          map.put(bytes)
        } finally {
          SharedMemory.unmap(map)
        }
        region.setProtect(OsConstants.PROT_READ)
      } catch (t: Throwable) {
        region.close()
        throw t
      }
      return Blob(null, region, bytes.size)
    }

    @JvmField
    val CREATOR: Parcelable.Creator<Blob> = object : Parcelable.Creator<Blob> {
      override fun createFromParcel(source: Parcel): Blob = when (source.readInt()) {
        MODE_INLINE -> {
          val b = source.createByteArray() ?: ByteArray(0)
          Blob(b, null, b.size)
        }
        else -> {
          val len = source.readInt()
          require(len in 0..Wire.MAX_MESSAGE) { "bad blob length $len" }
          Blob(null, SharedMemory.CREATOR.createFromParcel(source), len)
        }
      }

      override fun newArray(size: Int): Array<Blob?> = arrayOfNulls(size)
    }
  }
}
