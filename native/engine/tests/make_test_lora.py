"""Write a small random LoRA adapter GGUF for the host tests (no real adapter ships with the test model).

usage: python3 -I make_test_lora.py <llama.cpp tree> <base model.gguf> <out.gguf>

The adapter targets attn_q/attn_v of every layer with rank 8. Shapes follow llama-adapter.cpp:358-370:
lora_a ne = [n_in, r], lora_b ne = [r, n_out] (numpy shapes are reversed).
"""
import sys

def main() -> int:
    tree, base, out = sys.argv[1], sys.argv[2], sys.argv[3]
    sys.path.insert(0, tree + "/gguf-py")
    import numpy as np
    import gguf

    reader = gguf.GGUFReader(base)
    arch = bytes(reader.fields["general.architecture"].parts[-1]).decode()
    targets = {}
    for t in reader.tensors:
        if t.name.endswith(("attn_q.weight", "attn_v.weight")):
            n_in, n_out = int(t.shape[0]), int(t.shape[1])  # ggml ne order
            targets[t.name] = (n_in, n_out)
    if not targets:
        print("no attention tensors found", file=sys.stderr)
        return 1

    rng = np.random.default_rng(1234)
    rank = 8
    w = gguf.GGUFWriter(out, arch)
    w.add_string("general.type", "adapter")
    w.add_string("adapter.type", "lora")
    w.add_float32("adapter.lora.alpha", float(rank))
    for name, (n_in, n_out) in sorted(targets.items()):
        base_name = name
        a = (rng.standard_normal((rank, n_in)) * 0.05).astype(np.float32)
        b = (rng.standard_normal((n_out, rank)) * 0.05).astype(np.float32)
        w.add_tensor(base_name + ".lora_a", a)
        w.add_tensor(base_name + ".lora_b", b)
    w.write_header_to_file()
    w.write_kv_data_to_file()
    w.write_tensors_to_file()
    w.close()
    print(f"wrote {out}: {len(targets)} adapted tensors, rank {rank}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
