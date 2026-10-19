package io.github.mihok.sherpa_inference;

import io.github.mihok.sherpa_inference.Blob;

/** Implemented in the main process; the service pushes every InferenceMessage through it. */
oneway interface IInferenceClient {
    void receive(in Blob message);
}
