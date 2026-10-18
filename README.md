# Sherpa

An open, local-first **agent harness** for Android and iOS. Sherpa runs agent loops against on-device
models (llama.cpp, MLX, LiteRT-LM, platform models) or remote ones (OpenAI-compatible servers, the OpenAI
Responses API, Anthropic), finds models on the Hugging Face Hub, manages its own context under token and
memory pressure, and is a full **MCP** host: tools, resources, prompts, elicitation and MCP Apps.

> Status: under active development, milestone by milestone. See [docs/PLAN.md](docs/PLAN.md) for the
> architecture, decisions and risks, and [docs/research/](docs/research/) for the verified research it is
> based on.

## Milestones

| Milestone | Scope | Status |
|---|---|---|
| [M1](docs/milestones/M1.md) | Core agent loop, remote providers, chat UI | **Done** |
| M2 | Hugging Face directory, device fit, downloads, on-device inference + optimization | In progress (Hub client, name parser and device-fit engine landed) |
| M3 | Context manager: pruning, compaction, handoff, memory monitor | Core ladder landed; UI and memory plugin pending |
| M4 | MCP client, OAuth, approvals, tool budget | Planned |
| M5 | MCP Apps host, elicitation, sampling | Planned |
| M6 | Polish, accessibility, background execution, perf budgets, evals | Planned |

## Repository layout

| Path | What it is |
|---|---|
| `packages/sherpa_core` | Pure-Dart core: domain model, provider/tool/context interfaces, the agent loop |
| `packages/sherpa_net` | SSE decoder, SSRF-safe URL policy, retry/backoff, secret redaction |
| `packages/sherpa_providers` | Remote providers: Anthropic, OpenAI Chat (+ server quirk profiles), OpenAI Responses |
| `packages/sherpa_data` | Encrypted Drift/SQLite persistence |
| `packages/sherpa_markdown` | Incremental streaming Markdown renderer |
| `packages/sherpa_hub` | Hugging Face Hub client, model-name parser, device-fit engine, download planner |
| `app/` | The Flutter app |
| `native/` | `sherpa_engine` (C ABI over llama.cpp) and pinned build scripts |
| `docs/` | Plan, research digests, milestone notes |

## Development

Requirements: Flutter 3.47.7 (Dart 3.13.5). Android builds need the Android SDK with NDK 29.0.14206865;
iOS builds need Xcode on macOS.

```sh
flutter pub get            # one resolution for the whole pub workspace
tools/test_all.sh          # analyze + every package's tests
cd app && flutter run      # run the app
```

The database is encrypted with SQLite3MultipleCiphers. The `hooks.user_defines` block that selects it must
stay in the **root** `pubspec.yaml`; in a member pubspec it is silently ignored.

## License

MIT — see [LICENSE](LICENSE).
