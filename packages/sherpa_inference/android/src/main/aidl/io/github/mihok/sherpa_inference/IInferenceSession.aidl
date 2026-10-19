package io.github.mihok.sherpa_inference;

import io.github.mihok.sherpa_inference.Blob;

interface IInferenceSession {
    /** The service process id (exit-record lookup after a crash). */
    int pid();

    /**
     * One (requestId, EngineCall) pair encoded by Wire.encodeCall. Oneway: returns once the kernel queued
     * it. Oneway transactions to one binder node are delivered one at a time in order, which is what keeps
     * per-session calls in arrival order.
     */
    oneway void send(in Blob message);

    /** Frees everything this client created. */
    oneway void close();
}
