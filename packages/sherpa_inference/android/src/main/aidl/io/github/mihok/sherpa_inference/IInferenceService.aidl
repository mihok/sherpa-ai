// The :inference process's entry point (InferenceService.onBind). Binding is private to the app (the
// service is exported="false").
package io.github.mihok.sherpa_inference;

import io.github.mihok.sherpa_inference.IInferenceClient;
import io.github.mihok.sherpa_inference.IInferenceSession;

interface IInferenceService {
    /**
     * Registers [client] and returns a session for it: every attached client gets its own engine core
     * (handles, pump), torn down when the client dies or closes. Cheap and synchronous (called on the
     * plugin's IPC thread, never the platform main thread).
     */
    IInferenceSession attach(IInferenceClient client, int protocolVersion);
}
