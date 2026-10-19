// One encoded message (Wire.kt): inline bytes up to Wire.INLINE_MAX, else a read-only SharedMemory, so no
// transaction comes near the 1 MiB Binder buffer. Implemented in Blob.kt.
package io.github.mihok.sherpa_inference;

parcelable Blob;
