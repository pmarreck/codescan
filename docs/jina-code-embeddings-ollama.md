# Using jina-code-embeddings-1.5b locally through Ollama

## Known-good local state

Verified on 2026-07-22 with Ollama 0.32.0 on Linux x86_64 and an RTX 3080 Ti:

- Ollama model: `jina-code-embeddings:1.5b`
- architecture: Qwen2
- quantization: Q8_0
- embedding dimension: 1536
- runtime context: 8192 tokens
- service: `http://127.0.0.1:11434`
- authentication/Tailscale: neither is involved

Run the live acceptance gate:

```sh
./test_jina
```

It checks Ollama's advertised `embedding` capability and makes a real `/api/embed`
request, asserting the model name and 1536-dimensional result. The separate
`./test_jina_omlx` gate retains coverage for the remote Mac fallback.

## Why the raw Hugging Face pull does not embed

The official Q8_0 GGUF has SHA-256
`3a09a8817b852b5a4faaa6ebb1a5590322746d2b570b578d0b7e3b6e849062aa`.
It declares a 1536-dimensional Qwen2 model, but omits `qwen2.pooling_type`.
Ollama consequently advertises only `completion`; `/api/embed` returns HTTP 501
and reports that the server was not started for embeddings.

Jina's model card requires last-token/EOS pooling. Ollama derives embedding
capability from the GGUF `<architecture>.pooling_type` field, not from a
Modelfile parameter. The local model was therefore imported from a copy with:

```text
qwen2.pooling_type = 3  # LAST
```

The known-good patched GGUF SHA-256 is
`bedd1b9492544c6e03755857f757f98aa804f12ceb2abe7d34879d9c4c36a9db`.
Its only semantic metadata change is the pooling field; tensor data is copied
unchanged. Never edit Ollama's content-addressed blob in place.

The imported Modelfile is equivalent to:

```text
FROM /path/to/jina-q8-last-pooling.gguf
PARAMETER num_ctx 8192
```

The patching workspace used `/dev/shm`, which is RAM-backed on this host.
`TMPDIR=/tmp` is on the spinning ZFS mirror here and must not be used for this
multi-gigabyte rewrite.

The complete reproducible download, metadata-copy, import, validation, and
RAM-safe cleanup commands live in the README under
“Set up Jina locally through Ollama.”

Authoritative upstream references:

- [Jina GGUF model card](https://huggingface.co/jinaai/jina-code-embeddings-1.5b-GGUF)
- [Ollama pooling-metadata requirement](https://github.com/ollama/ollama/issues/10989)
- [llama.cpp GGUF pooling key and enum](https://github.com/ggml-org/llama.cpp/blob/master/gguf-py/gguf/constants.py)

## codescan configuration

```ini
embedding_api=ollama
embedding_url=http://127.0.0.1:11434
embedding_model=jina-code-embeddings:1.5b
embedding_dim=1536
```

After changing from another model name or dimension, run `codescan update`; it
detects the mismatch and regenerates the project index.
On the codescan repository the verified local rebuild produced 7,161 code
embeddings and 825 comment embeddings; a pure-vector repository-boundary query
returned `findRepoRootInfoUntil` first.
