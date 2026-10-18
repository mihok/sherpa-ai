<!-- Verbatim copy of docs/research/08-hf-hub.md §14 (LIVE 2026-10-18). Do not edit: name_corpus_test.dart
     checks that every row here has a normalized expectation in r08_corpus_expected.json. -->

## 14. Test corpus (verbatim, LIVE 2026-10-18)

Columns: fmt = gguf/mlx/st (safetensors)/gptq/awq/exl2/exl3/litert/onnx/pickle/ggml; bpw = nominal or
"(live)" effective where measured; "dyn" = dynamic mix (use file size). Empty = not present in name.
"repo" in the file column means the row tests the repo id (weights are generic `model*.safetensors`).

| # | repo id | file / branch | fmt | family | ver | size | active | variant | quant | bpw | shard / role / note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | unsloth/Qwen3.8-27B-GGUF | Qwen3.8-27B-UD-Q4_K_XL.gguf | gguf | Qwen | 3.8 | 27B | | | UD-Q4_K_XL | dyn | model |
| 2 | unsloth/Qwen3.8-27B-GGUF | BF16/Qwen3.8-27B-BF16-00001-of-00002.gguf | gguf | Qwen | 3.8 | 27B | | | BF16 | 16 | shard 1/2, folder |
| 3 | unsloth/Qwen3.8-27B-GGUF | MTP/mtp-Qwen3.8-27B-Q4_0.gguf | gguf | Qwen | 3.8 | 27B | | | Q4_0 | 4.5 | role=draft(mtp) |
| 4 | unsloth/Qwen3.8-27B-GGUF | mmproj-F16.gguf | gguf | (from repo) | | | | | F16 | 16 | role=mmproj, name only in repo |
| 5 | unsloth/Qwen3.8-27B-GGUF | imatrix_unsloth.gguf | gguf | | | | | | | | role=imatrix (not loadable) |
| 6 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | UD-Q4_K_XL | 4.63 (live) | 17,665,334,432 B |
| 7 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | Qwen3-Coder-30B-A3B-Instruct-UD-TQ1_0.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | UD-TQ1_0 | 2.10 (live) | |
| 8 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | Qwen3-Coder-30B-A3B-Instruct-Q2_K_L.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | Q2_K_L | 2.97 (live) | |
| 9 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | BF16/Qwen3-Coder-30B-A3B-Instruct-BF16-00002-of-00002.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | BF16 | 16 | shard 2/2 |
| 10 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | imatrix_unsloth.gguf_file | other | | | | | | | | role=imatrix, odd extension |
| 11 | unsloth/Qwen3-Coder-30B-A3B-Instruct-1M-GGUF | Qwen3-Coder-30B-A3B-Instruct-1M-Q2_K.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | Q2_K | 2.95 | `1M` = context, not size |
| 12 | unsloth/Qwen3.6-35B-A3B-GGUF | Qwen3.6-35B-A3B-MXFP4_MOE.gguf | gguf | Qwen | 3.6 | 35B | 3B | | MXFP4_MOE | ~4.25 experts | |
| 13 | unsloth/Qwen3.6-35B-A3B-GGUF | Qwen3.6-35B-A3B-UD-IQ4_NL_XL.gguf | gguf | Qwen | 3.6 | 35B | 3B | | UD-IQ4_NL_XL | dyn | |
| 14 | unsloth/Qwen3.6-35B-A3B-GGUF | Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf | gguf | Qwen | 3.6 | 35B | 3B | | UD-Q8_K_XL | dyn (9.4 on 30B) | no real Q8_K ftype |
| 15 | unsloth/Muse-Spark-Open-816B-A42B-GGUF | UD-IQ1_S/Muse-Spark-Open-816B-A42B-UD-IQ1_S-00001-of-00005.gguf | gguf | Muse Spark Open | | 816B | 42B | | UD-IQ1_S | dyn | shard 1/5 in quant folder |
| 16 | unsloth/gemma-3-270m-it-GGUF | gemma-3-270m-it-Q8_0.gguf | gguf | Gemma | 3 | 270M | | it | Q8_0 | 8.70 (live) | |
| 17 | unsloth/gemma-3-270m-it-GGUF | gemma-3-270m-it-Q2_K.gguf | gguf | Gemma | 3 | 270M | | it | Q2_K | **7.07 (live)** | name-bpw trap |
| 18 | unsloth/gemma-4-12b-it-GGUF | gemma-4-12b-it-UD-Q4_K_XL.gguf | gguf | Gemma | 4 | 12B | | it | UD-Q4_K_XL | dyn | lowercase `b` |
| 19 | unsloth/gemma-4-12b-it-GGUF | mtp-gemma-4-12b-it.gguf | gguf | Gemma | 4 | 12B | | it | (none) | ? | role=draft(mtp); read header |
| 20 | unsloth/embeddinggemma-2-GGUF | embeddinggemma-2-UD-Q4_K_XL.gguf | gguf | EmbeddingGemma | 2 | | | Embedding | UD-Q4_K_XL | dyn | no size token |
| 21 | unsloth/Qwen3-30B-A3B-Thinking-2507-GGUF | Qwen3-30B-A3B-Thinking-2507-Q4_K_M.gguf | gguf | Qwen | 3 (build 2507) | 30B | 3B | Thinking | Q4_K_M | ~4.86 | |
| 22 | unsloth/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-GGUF | NVFP4/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4-00001-of-00003.gguf | gguf | Nemotron (NVIDIA) | 3.5 | 120B | 12B | Super, VL | NVFP4 | 4.5 | shard 1/3 |
| 23 | unsloth/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-GGUF | LiLiCorr/lilicorr-NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4.gguf | gguf | Nemotron | 3.5 | 120B | 12B | Super, VL | NVFP4 | 4.5 | unknown sidecar prefix → not primary |
| 24 | unsloth/MiniMax-H3-GGUF | minimax_h3_fl2va_pruned-Q4_K.gguf | gguf | MiniMax | H3 | | | pruned | Q4_K (=Q4_K_M) | ~4.9 | `_` separators; video-gen (not LLM) |
| 25 | bartowski/Llama-3.2-3B-Instruct-GGUF | Llama-3.2-3B-Instruct-Q4_0_4_4.gguf | gguf | Llama | 3.2 | 3B | | Instruct | Q4_0_4_4 | 4.5 | **deprecated: won't load** |
| 26 | bartowski/Llama-3.2-3B-Instruct-GGUF | Llama-3.2-3B-Instruct-Q3_K_XL.gguf | gguf | Llama | 3.2 | 3B | | Instruct | Q3_K_XL | Q3_K_L + Q8_0 embed/out | |
| 27 | bartowski/Llama-3.2-3B-Instruct-GGUF | Llama-3.2-3B-Instruct-Q6_K_L.gguf | gguf | Llama | 3.2 | 3B | | Instruct | Q6_K_L | ≥6.56 | |
| 28 | bartowski/Llama-3.2-3B-Instruct-GGUF | Llama-3.2-3B-Instruct-f16.gguf | gguf | Llama | 3.2 | 3B | | Instruct | F16 | 16 | lowercase |
| 29 | bartowski/Llama-3.2-1B-Instruct-GGUF | Llama-3.2-1B-Instruct-Q4_K_M.gguf | gguf | Llama | 3.2 | 1B | | Instruct | Q4_K_M | 5.23 (live) | header: size_label=1B, file_type=15 |
| 30 | bartowski/Qwen2.5-7B-Instruct-GGUF | Qwen2.5-7B-Instruct-Q4_K_L.gguf | gguf | Qwen | 2.5 | 7B | | Instruct | Q4_K_L | ≥4.89 | |
| 31 | bartowski/Qwen2.5-7B-Instruct-GGUF | Qwen2.5-7B-Instruct.imatrix | other | Qwen | 2.5 | 7B | | Instruct | | | role=imatrix |
| 32 | bartowski/google_gemma-4-E2B-it-GGUF | google_gemma-4-E2B-it-Q4_K_M.gguf | gguf | Gemma (google) | 4 | E2B | | it | Q4_K_M | ~4.9 | effective-param label |
| 33 | bartowski/google_gemma-3n-E4B-it-GGUF | google_gemma-3n-E4B-it-Q4_K_M.gguf | gguf | Gemma 3n (google) | 3n | E4B (7.85B raw) | | it | Q4_K_M | ~4.9 | |
| 34 | bartowski/Qwen_Qwen3.6-35B-A3B-GGUF | Qwen_Qwen3.6-35B-A3B-IQ1_M.gguf | gguf | Qwen (Qwen_) | 3.6 | 35B | 3B | | IQ1_M | 1.75 | publisher prefix |
| 35 | bartowski/thomsonreuters_Thomson-1.0-Small-GGUF | mmproj-thomsonreuters_Thomson-1.0-Small-f16.gguf | gguf | Thomson (thomsonreuters_) | 1.0 | Small | | | F16 | 16 | role=mmproj; size word |
| 36 | bartowski/Mellum2.1-12B-A2.5B-Thinking-GGUF | Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf | gguf | Mellum | 2.1 | 12B | 2.5B | Thinking | Q4_K_M | ~4.9 | glued version, decimal active |
| 37 | bartowski/Mellum2.1-12B-A2.5B-Thinking-GGUF | layouts/Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.layout.json | other | | | | | | | | non-weight sidecar → ignore |
| 38 | bartowski/TheDrummer_Orion-26B-A4B-v1.1-GGUF | TheDrummer_Orion-26B-A4B-v1.1-Q4_K_M.gguf | gguf | Orion (TheDrummer_) | v1.1 | 26B | 4B | | Q4_K_M | ~4.9 | |
| 39 | bartowski/L3-8B-Stheno-v3.2-GGUF | L3-8B-Stheno-v3.2-Q4_K_M.gguf | gguf | Stheno (base L3=Llama 3) | v3.2 | 8B | | | Q4_K_M | ~4.9 | size before name |
| 40 | bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF | MiMo-V2.6-Distill-Qwen-9B-Q4_K_M.gguf | gguf | MiMo→Qwen | V2.6 | 9B | | Distill | Q4_K_M | ~4.9 | teacher-student name |
| 41 | bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF | Kwaipilot_KAT-Coder-V2.5-Dev-IQ2_M.gguf | gguf | KAT (Kwaipilot_) | V2.5 | | | Coder, Dev | IQ2_M | 2.7 | no size |
| 42 | mradermacher/Cyber-Ornith-1.5-9B-OBLITERATED-i1-GGUF | Cyber-Ornith-1.5-9B-OBLITERATED.i1-Q4_K_M.gguf | gguf | Ornith (Cyber-) | 1.5 | 9B | | OBLITERATED | i1-Q4_K_M | ~4.9 | `.` separator, imatrix |
| 43 | mradermacher/Cyber-Ornith-1.5-9B-OBLITERATED-i1-GGUF | Cyber-Ornith-1.5-9B-OBLITERATED.i1-IQ1_S.gguf | gguf | Ornith | 1.5 | 9B | | OBLITERATED | i1-IQ1_S | 1.56 | |
| 44 | mradermacher/Ornith-1.5-9B-uncensored-GGUF | Ornith-1.5-9B-uncensored.mmproj-f16.gguf | gguf | Ornith | 1.5 | 9B | | uncensored | F16 | 16 | role=mmproj (dot form) |
| 45 | mradermacher/Ornith-1.5-9B-uncensored-GGUF | Ornith-1.5-9B-uncensored.Q8_0.gguf | gguf | Ornith | 1.5 | 9B | | uncensored | Q8_0 | 8.5 | |
| 46 | mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF | Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf.part1of2 | gguf-part | Llama | 3.3 | 70B | | Instruct, abliterated | Q8_0 | 8.5 | **byte split 1/2 → concatenate** |
| 47 | mradermacher/Meta-Llama-3-70B-Instruct-i1-GGUF | Meta-Llama-3-70B-Instruct.i1-Q6_K.gguf.part1of2 | gguf-part | Llama (Meta-) | 3 | 70B | | Instruct | i1-Q6_K | 6.56 | byte split 1/2 |
| 48 | mradermacher/Qwen3.5-9B-Kimi-k3-Distilled-GGUF | Qwen3.5-9B-Kimi-k3-Distilled.Q4_K_M.gguf | gguf | Qwen | 3.5 | 9B | | Distilled (from Kimi k3) | Q4_K_M | ~4.9 | teacher after size |
| 49 | mradermacher/LFM2.5-24B-A2B-i1-GGUF | LFM2.5-24B-A2B.i1-Q4_K_M.gguf | gguf | LFM | 2.5 | 24B | 2B | | i1-Q4_K_M | ~4.9 | |
| 50 | lmstudio-community/Qwen3.8-27B-GGUF | mmproj-Qwen3.8-27B-BF16.gguf | gguf | Qwen | 3.8 | 27B | | | BF16 | 16 | role=mmproj |
| 51 | lmstudio-community/Llama-3-Groq-8B-Tool-Use-GGUF | Llama-3-Groq-8B-Tool-Use-Q4_K_M.gguf | gguf | Llama (Groq) | 3 | 8B | | Tool-Use | Q4_K_M | ~4.9 | tags: tool-use, function-calling |
| 52 | lmstudio-community/Mistral-7B-Instruct-v0.3-GGUF | Mistral-7B-Instruct-v0.3-IQ4_NL.gguf | gguf | Mistral | v0.3 | 7B | | Instruct | IQ4_NL | 4.5 | version after variant |
| 53 | ggml-org/gpt-oss-20b-GGUF | gpt-oss-20b-MXFP4.gguf | gguf | gpt-oss | | 20B | (not in name) | | MXFP4 | 4.25 | MoE without A-token |
| 54 | ggml-org/gpt-oss-20b-GGUF | eagle3-gpt-oss-20b-Q8_0.gguf | gguf | gpt-oss | | 20B | | | Q8_0 | 8.5 | role=draft(eagle3) |
| 55 | ggml-org/Qwen3.8-27B-GGUF | dflash-Qwen3.8-27B-Q4_0.gguf | gguf | Qwen | 3.8 | 27B | | | Q4_0 | 4.5 | role=draft(dflash) |
| 56 | ggml-org/gemma-4-E4B-it-GGUF | mmproj-gemma-4-E4B-it-Q8_0.gguf | gguf | Gemma | 4 | E4B | | it | Q8_0 | 8.5 | role=mmproj |
| 57 | ggml-org/gemma-4-E4B-it-GGUF | mtp-gemma-4-E4B-it-BF16.gguf | gguf | Gemma | 4 | E4B | | it | BF16 | 16 | role=draft(mtp) |
| 58 | ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF | NVIDIA-Nemotron-3.5-Lightning-30B-A3B-Q4_0.gguf | gguf | Nemotron (NVIDIA) | 3.5 | 30B | 3B | Lightning | Q4_0 | 4.5 | |
| 59 | ggml-org/Muse-Spark-Open-816B-A42B-GGUF | Muse-Spark-Open-816B-A42B-BF16-00001-of-00022.gguf | gguf | Muse Spark Open | | 816B | 42B | | BF16 | 16 | shard 1/22 |
| 60 | ggml-org/gemma-3-270m-qat-GGUF | gemma-3-270m-qat-Q4_0.gguf | gguf | Gemma | 3 | 270M | | qat | Q4_0 | 4.5 | |
| 61 | ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF | qwen3-reranker-0.6b-q8_0.gguf | gguf | Qwen | 3 | 0.6B | | Reranker | Q8_0 | 8.5 | quant also in repo name |
| 62 | ggml-org/models-moved | mistral-7b-v0.2-iq3_s-imat.gguf | gguf | Mistral | v0.2 | 7B | | | IQ3_S (imatrix) | 3.44 | `-imat` suffix after quant |
| 63 | ggml-org/models-moved | bert-bge-small/ggml-model-f16-big-endian.gguf | gguf | BGE (bert) | | small | | | F16 | 16 | **big-endian: reject** |
| 64 | ggml-org/SmolLM3-3B-GGUF | SmolLM3-Q4_K_M.gguf | gguf | SmolLM | 3 | (3B from repo) | | | Q4_K_M | ~4.9 | merge repo+file |
| 65 | Qwen/Qwen2.5-Coder-7B-Instruct-GGUF | qwen2.5-coder-7b-instruct-q4_k_m-00001-of-00002.gguf | gguf | Qwen | 2.5 | 7B | | Coder, Instruct | Q4_K_M | ~4.9 | lowercase, shard 1/2 |
| 66 | Qwen/Qwen2.5-Coder-7B-Instruct-GGUF | qwen2.5-coder-7b-instruct-fp16.gguf | gguf | Qwen | 2.5 | 7B | | Coder, Instruct | F16 (`fp16`) | 16 | also ships fp16 shards of same |
| 67 | mistralai/Ministral-3-3B-Instruct-2512-GGUF | Ministral-3-3B-Instruct-2512-BF16-mmproj.gguf | gguf | Ministral | 3 (build 2512) | 3B | | Instruct | BF16 | 16 | role=mmproj (suffix) |
| 68 | ibm-granite/granite-4.2-8b-GGUF | granite-4.2-8b-Q4_1.gguf | gguf | Granite | 4.2 | 8B | | | Q4_1 | 5.0 | |
| 69 | LiquidAI/LFM2.5-8B-A1B-GGUF | LFM2.5-8B-A1B-Q4_K_M.gguf | gguf | LFM | 2.5 | 8B | 1B | | Q4_K_M | ~4.9 | |
| 70 | LiquidAI/LFM2.5-230M-GGUF | LFM2.5-230M-QAD-Q4_0.gguf | gguf | LFM | 2.5 | 230M | | QAD | Q4_0 | 4.5 | |
| 71 | LiquidAI/LFM2.5-Audio-1.5B-GGUF | mmproj-LFM2.5-Audio-1.5B-Q8_0.gguf | gguf | LFM | 2.5 | 1.5B | | Audio | Q8_0 | 8.5 | role=mmproj (audio) |
| 72 | HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF | smollm2-1.7b-instruct-q4_k_m.gguf | gguf | SmolLM | 2 | 1.7B | | Instruct | Q4_K_M | ~4.9 | |
| 73 | microsoft/Phi-3-mini-4k-instruct-gguf | Phi-3-mini-4k-instruct-q4.gguf | gguf | Phi | 3 | mini | | instruct | `q4` (ambiguous) | ? | `4k` = context; read header |
| 74 | TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF | mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf | gguf | Mixtral | v0.1 | 8x7B | | instruct | Q4_K_M | ~4.9 | experts token |
| 75 | TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF | tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf | gguf | TinyLlama | v1.0 | 1.1B | | chat | Q4_K_M | ~4.9 | |
| 76 | TheBloke/Llama-2-7B-Chat-GGML | llama-2-7b-chat.ggmlv3.q4_0.bin | ggml | Llama | 2 | 7B | | chat | q4_0 | 4.5 | **legacy GGML: unsupported** |
| 77 | TheBloke/Vicuna-13B-1.1-GPTQ | vicuna-13B-1.1-GPTQ-4bit-128g.compat.no-act-order.pt | pickle | Vicuna | 1.1 | 13B | | | GPTQ 4bit g128 | ~4.16 | **pickle: block** |
| 78 | TheBloke/Llama-2-7B-Chat-GPTQ | branch `gptq-4bit-32g-actorder_True` | gptq | Llama | 2 | 7B | | Chat | GPTQ 4bit g32 | ~4.6 | variant in branch |
| 79 | mlx-community/Qwen3-8B-4bit | repo | mlx | Qwen | 3 | 8B | | | 4bit gs64 | 4.5 | config `{"group_size":64,"bits":4}` |
| 80 | mlx-community/Qwen2.5-Coder-0.5B-4bit-gs32 | repo | mlx | Qwen | 2.5 | 0.5B | | Coder | 4bit gs32 | 5.0 | |
| 81 | mlx-community/Qwen3.8-27B-mxfp4 | repo | mlx | Qwen | 3.8 | 27B | | | mxfp4 gs32 | 4.25 | config mode=mxfp4 |
| 82 | mlx-community/gpt-oss-20b-MXFP4-Q8 | repo | mlx | gpt-oss | | 20B | | | MXFP4 + Q8 | mixed | |
| 83 | mlx-community/Qwen3-Coder-30B-A3B-Instruct-6bit-DWQ-lr3e-7 | repo | mlx | Qwen | 3 | 30B | 3B | Coder, Instruct | 6bit DWQ | ~6.5 | `lr3e-7` noise token |
| 84 | mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ | repo | mlx | Qwen | 3 | 0.6B | | Embedding | 4bit DWQ | 4.5 | |
| 85 | mlx-community/gemma-3n-E2B-it-lm-4bit | repo | mlx | Gemma 3n | 3n | E2B | | it, lm(text-only) | 4bit | 4.5 | |
| 86 | mlx-community/Llama-3.3-70B-Instruct-3bit | repo | mlx | Llama | 3.3 | 70B | | Instruct | 3bit | 3.5 | |
| 87 | lmstudio-community/Qwen3.8-27B-MLX-6bit | repo | mlx | Qwen | 3.8 | 27B | | | 6bit | 6.5 | `-MLX-` marker |
| 88 | lmstudio-community/Qwen3-4B-Thinking-2507-MLX-4bit | repo | mlx | Qwen | 3 (2507) | 4B | | Thinking | 4bit | 4.5 | |
| 89 | mlx-community/MiMo-V2.6-Flash-RL-mxfp4-q8 | repo | mlx | MiMo | V2.6 | Flash | | RL | mxfp4 + q8 | mixed | |
| 90 | mlx-community/DeepSeek-V4.1-Flash-1017-oQ4e-mtp | repo | mlx | DeepSeek | V4.1 (build 1017) | Flash | | mtp | oQ4e (UNVERIFIED) | ? | unknown scheme |
| 91 | mlx-community/whisper-small-mlx | weights.npz | mlx-npz | Whisper | | small | | | | | legacy npz, ASR |
| 92 | Qwen/Qwen2.5-7B-Instruct-GPTQ-Int4 | repo | gptq | Qwen | 2.5 | 7B | | Instruct | GPTQ Int4 g128 | ~4.16 | st total 7.6B logical |
| 93 | Qwen/Qwen3-8B-AWQ | repo | awq | Qwen | 3 | 8B | | | AWQ 4bit g128 | ~4.16 | |
| 94 | Qwen/Qwen3-235B-A22B-Instruct-2507-FP8 | repo | st | Qwen | 3 (2507) | 235B | 22B | Instruct | FP8 | 8 | F8_E4M3 dtype |
| 95 | google/gemma-4-E2B-it-qat-w4a16-ct | repo | st (compressed-tensors) | Gemma | 4 | E2B | | it, qat | w4a16 | ~4.2 | `ct` = compressed-tensors |
| 96 | nm-testing/SmolLM-1.7B-Instruct-quantized.w4a16 | repo | st | SmolLM | | 1.7B | | Instruct | w4a16 | ~4.2 | `.` before quant |
| 97 | unsloth/Qwen3-4B-Instruct-2507-unsloth-bnb-4bit | repo | st (bnb) | Qwen | 3 (2507) | 4B | | Instruct | bnb-4bit | ~4.5 | GPU-only; skip on mobile |
| 98 | unsloth/Qwen3.8-27B-NVFP4 | model_mtp.safetensors | st | Qwen | 3.8 | 27B | | | NVFP4 | 4.5 | role=draft(mtp) safetensors |
| 99 | casperhansen/deepseek-r1-distill-qwen-32b-awq | repo | awq | DeepSeek R1→Qwen | R1 | 32B | | Distill | AWQ | ~4.16 | all lowercase |
| 100 | bartowski/L3-8B-Stheno-v3.2-exl2 | branch `4_25` | exl2 | Stheno (L3) | v3.2 | 8B | | | EXL2 | 4.25 | bpw in branch, `_` decimal |
| 101 | turboderp/Qwen3.8-27B-exl3 | branch `SC_4.00bpw_H5_V6` | exl3 | Qwen | 3.8 | 27B | | | EXL3 | 4.00 | H5 head bits; main has only `cal_trace.safetensors` |
| 102 | LoneStriker/Nous-Capybara-34B-5.0bpw-h6-exl2 | output-00001-of-00003.safetensors | exl2 | Capybara (Nous) | | 34B | | | EXL2 | 5.0 (h6) | |
| 103 | speakleash/Bielik-11B-v2.2-Instruct-EXL2-4.5bit | repo | exl2 | Bielik | v2.2 | 11B | | Instruct | EXL2 | 4.5 | `bit` not `bpw` |
| 104 | litert-community/gemma-4-E2B-it-litert-lm | gemma-4-E2B-it_Google_Tensor_G5.litertlm | litert | Gemma | 4 | E2B | | it | (SoC build) | ? | device=Tensor G5 NPU |
| 105 | litert-community/gemma-4-E2B-it-litert-lm | gemma-4-E2B-it-web.task | litert | Gemma | 4 | E2B | | it | | ? | target=web |
| 106 | litert-community/Qwen2.5-1.5B-Instruct | Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm | litert | Qwen | 2.5 | 1.5B | | Instruct | q8 | ~8 | ekv4096 = KV len (inferred) |
| 107 | litert-community/Gemma3-1B-IT | Gemma3-1B-IT_multi-prefill-seq_q4_block128_ekv4096.task | litert | Gemma | 3 | 1B | | IT | q4 block128 | ~4.1 | glued version, uppercase IT |
| 108 | litert-community/gemma-3-270m-it | gemma3-270m-it-q8.qualcomm.sm8650.litertlm | litert | Gemma | 3 | 270M | | it | q8 | ~8 | device=Snapdragon SM8650 |
| 109 | litert-community/Qwen3-0.6B | Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm | litert | Qwen | 3 | 0.6B | | | int4 w, block32, fp32 act | ~4.5 | |
| 110 | google/gemma-3n-E2B-it-litert-lm | gemma-3n-E2B-it-int4.litertlm | litert | Gemma 3n | 3n | E2B | | it | int4 | ~4 | |
| 111 | HuggingFaceTB/SmolLM2-135M-Instruct | onnx/model_q4f16.onnx | onnx | SmolLM | 2 | 135M | | Instruct | q4f16 | ~4 | |
| 112 | LiquidAI/LFM2.5-24B-A2B-ONNX | onnx/model_q4f16.onnx_data | onnx-data | LFM | 2.5 | 24B | 2B | | q4f16 | | external weights of model_q4f16.onnx |
| 113 | meta-llama/Llama-3.1-8B-Instruct | original/consolidated.00.pth | pickle | Llama | 3.1 | 8B | | Instruct | | 16 | **pickle: skip**; gated manual |
| 114 | mistralai/Mixtral-8x7B-Instruct-v0.1 | consolidated.00.pt | pickle | Mixtral | v0.1 | 8x7B | | Instruct | | | **pickle: skip** |
| 115 | mistralai/Mistral-7B-Instruct-v0.2 | pytorch_model-00001-of-00003.bin | pickle | Mistral | v0.2 | 7B | | Instruct | | | **pickle**, shard 1/3 |
| 116 | deepseek-ai/DeepSeek-R1-Distill-Qwen-7B | model-00001-of-000002.safetensors | st | DeepSeek R1→Qwen | R1 | 7B | | Distill | BF16 | 16 | **6-digit shard total** |
| 117 | Qwen/Qwen3.5-4B | model.safetensors-00001-of-00002.safetensors | st | Qwen | 3.5 | 4B | | | BF16 | 16 | odd shard prefix |
| 118 | google/gemma-3n-E2B-it | repo | st | Gemma 3n | 3n | E2B | | it | BF16 | 16 | raw 5,439,438,272 params |
| 119 | Qwen/Qwen3-30B-A3B-Thinking-2507 | repo | st | Qwen | 3 (2507) | 30B | 3B | Thinking | BF16 | 16 | 30,532,122,624 params |
| 120 | microsoft/Phi-4-mini-reasoning | repo | st | Phi | 4 | mini | | Reasoning | BF16 | 16 | 3,836,021,760 params |
| 121 | mistralai/Mistral-Small-3.2-24B-Instruct-2506 | repo | st | Mistral | 3.2 (2506) | 24B (Small) | | Instruct | | | tier + size + date |
| 122 | mistralai/Devstral-Small-2-24B-Instruct-2512 | repo | st | Devstral | 2 (2512) | 24B (Small) | | Instruct | | | version between tier and size |
| 123 | HuggingFaceTB/SmolLM3-3B-Base | repo | st | SmolLM | 3 | 3B | | Base | | | |
| 124 | meta-llama/Llama-3.1-405B-FP8 | repo | st | Llama | 3.1 | 405B | | | FP8 | 8 | 221 weight files |
| 125 | Qwen/Qwen3.8-Flash-Next | repo | st | Qwen | 3.8 | (Flash) | | Next | | | no size token; 131 shards |
| 126 | mistralai/Mixtral-8x22B-Instruct-v0.1 | repo | st | Mixtral | v0.1 | 8x22B | | Instruct | | | |
| 127 | HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF | Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-FastMTP-32K.gguf | gguf | Qwen | 3.8 | 27B | | Uncensored, Aggressive | (none) | ? | role=draft (FastMTP), `32K` context; Hub `gguf` summary came from this file |
| 128 | HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF | Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf | gguf | Qwen | 3.8 | 27B | | Uncensored, Aggressive | Q4_K_P | 5.25 (live) | custom label |

Sizes for live-bpw rows came from `tree` (bytes) ÷ `safetensors.total` or `gguf.total` of the same repo.
