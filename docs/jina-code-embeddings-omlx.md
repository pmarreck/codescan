# Using jina-code-embeddings-1.5b with oMLX Server

## Why jina-code-embeddings?

codescan defaults to `jina-code-embeddings-1.5b` because it's purpose-built for code search:

| Feature | jina-code-embeddings-1.5b | bge-large (previous default) |
|---------|---------------------------|------------------------------|
| **Dimensions** | 1536 | 1024 |
| **Context window** | 32K tokens | 512 tokens |
| **Training** | Code-specific (nl2code, code2code, code2nl, QA, completion) | General-purpose |
| **Matryoshka** | Yes (truncatable to 128/256/512/896 dims) | No |
| **Size** | 1.5B params (~1.5GB) | 335M params (~670MB) |
| **License** | CC-BY-NC-4.0 (non-commercial) | MIT |

The 32K context window is the biggest practical win — it can embed entire functions and large code blocks without truncation, which dramatically improves search relevance for code.

## oMLX Server Setup

[oMLX Server](https://github.com/jundot/omlx) runs MLX models natively on Apple Silicon with significantly faster inference than Ollama's llama.cpp Metal backend. However, as of April 2026, oMLX does not natively recognize Qwen2-based embedding models (like jina-code-embeddings). This guide documents the patches needed to make it work.

### 1. Download the MLX model

```bash
# Using nix (recommended — avoids polluting global Python)
nix shell nixpkgs#python312Packages.huggingface-hub \
  -c huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx \
  --local-dir ~/.omlx/models/jina-code-embeddings-1.5b-mlx

# Or with pip (if you prefer)
pip install huggingface-hub
huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx \
  --local-dir ~/.omlx/models/jina-code-embeddings-1.5b-mlx
```

### 2. Fix the model's config.json

The MLX conversion dropped the `architectures` field. Add it back:

```bash
python3 -c "
import json
path = '$HOME/.omlx/models/jina-code-embeddings-1.5b-mlx/config.json'
with open(path) as f:
    d = json.load(f)
d['architectures'] = ['Qwen2ForCausalLM']
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
print('Done')
"
```

### 3. Patch oMLX model discovery

oMLX's model discovery only recognizes `Qwen3ForCausalLM` as a CausalLM-based embedding architecture. Qwen2 needs to be added.

Edit `/Applications/oMLX.app/Contents/Resources/omlx/model_discovery.py` and find the `CAUSAL_LM_EMBEDDING_ARCHITECTURES` set (around line 129):

```python
# Before:
CAUSAL_LM_EMBEDDING_ARCHITECTURES = {
    "Qwen3ForCausalLM",  # Qwen3-Embedding uses CausalLM arch without lm_head
}

# After:
CAUSAL_LM_EMBEDDING_ARCHITECTURES = {
    "Qwen3ForCausalLM",  # Qwen3-Embedding uses CausalLM arch without lm_head
    "Qwen2ForCausalLM",  # jina-code-embeddings-1.5b uses Qwen2 backbone
}
```

Then delete the cached bytecode so Python picks up the change:

```bash
rm -f /Applications/oMLX.app/Contents/Resources/omlx/__pycache__/model_discovery.cpython-311.pyc
```

### 4. Add Qwen2 embedding support to mlx-embeddings

This is the main patch. oMLX uses `mlx-embeddings` to load embedding models, and it has no Qwen2 implementation. Create one by adapting the existing Qwen3 implementation.

Save the following as `/Applications/oMLX.app/Contents/Python/framework-mlx-framework/lib/python3.11/site-packages/mlx_embeddings/models/qwen2.py`:

<details>
<summary>Click to expand qwen2.py (~180 lines)</summary>

```python
"""Qwen2 embedding model for mlx-embeddings (adapted from qwen3.py)."""

import logging
import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Union

import mlx.core as mx
import mlx.nn as nn

from .base import BaseModelArgs, BaseModelOutput, normalize_embeddings


def last_token_pool(
    last_hidden_states: mx.array, attention_mask: Optional[mx.array] = None
) -> mx.array:
    if attention_mask is None:
        return last_hidden_states[:, -1]
    left_padding = attention_mask[:, -1].sum() == attention_mask.shape[0]
    if left_padding:
        return last_hidden_states[:, -1]
    else:
        sequence_lengths = attention_mask.sum(axis=1) - 1
        batch_size = last_hidden_states.shape[0]
        return last_hidden_states[mx.arange(batch_size), sequence_lengths]


@dataclass
class ModelArgs(BaseModelArgs):
    model_type: str = "qwen2"
    hidden_size: int = 1536
    num_hidden_layers: int = 28
    intermediate_size: int = 8960
    num_attention_heads: int = 12
    num_key_value_heads: Optional[int] = None
    head_dim: Optional[int] = None
    max_position_embeddings: int = 32768
    vocab_size: int = 151936
    rms_norm_eps: float = 1e-6
    rope_theta: float = 1000000.0
    rope_scaling: Optional[Dict[str, Union[float, str]]] = None
    attention_bias: bool = True  # Qwen2 uses bias (unlike Qwen3)
    tie_word_embeddings: bool = True
    hidden_act: str = "silu"
    use_sliding_window: bool = False
    sliding_window: Optional[int] = None
    bos_token_id: Optional[int] = None
    eos_token_id: Optional[int] = None
    pad_token_id: Optional[int] = None
    architectures: List[str] = field(default_factory=lambda: ["Qwen2ForCausalLM"])
    initializer_range: float = 0.02

    def __post_init__(self):
        if self.num_key_value_heads is None:
            self.num_key_value_heads = self.num_attention_heads
        if self.head_dim is None:
            self.head_dim = self.hidden_size // self.num_attention_heads


class Qwen2MLP(nn.Module):
    def __init__(self, config: ModelArgs):
        super().__init__()
        self.gate_proj = nn.Linear(
            config.hidden_size, config.intermediate_size, bias=False
        )
        self.up_proj = nn.Linear(
            config.hidden_size, config.intermediate_size, bias=False
        )
        self.down_proj = nn.Linear(
            config.intermediate_size, config.hidden_size, bias=False
        )

    def __call__(self, x: mx.array) -> mx.array:
        return self.down_proj(nn.silu(self.gate_proj(x)) * self.up_proj(x))


class Qwen2Attention(nn.Module):
    def __init__(self, config: ModelArgs):
        super().__init__()
        self.hidden_size = config.hidden_size
        self.num_heads = config.num_attention_heads
        self.head_dim = config.head_dim
        self.num_key_value_heads = config.num_key_value_heads
        self.num_key_value_groups = self.num_heads // self.num_key_value_heads

        self.q_proj = nn.Linear(
            self.hidden_size,
            self.num_heads * self.head_dim,
            bias=config.attention_bias,
        )
        self.k_proj = nn.Linear(
            self.hidden_size,
            self.num_key_value_heads * self.head_dim,
            bias=config.attention_bias,
        )
        self.v_proj = nn.Linear(
            self.hidden_size,
            self.num_key_value_heads * self.head_dim,
            bias=config.attention_bias,
        )
        self.o_proj = nn.Linear(
            self.num_heads * self.head_dim, self.hidden_size, bias=False
        )

        # No q_norm/k_norm in Qwen2 (unlike Qwen3)

        self.rotary_emb = nn.RoPE(
            self.head_dim, traditional=False, base=config.rope_theta
        )

    def __call__(
        self,
        hidden_states: mx.array,
        attention_mask: Optional[mx.array] = None,
        **kwargs,
    ) -> mx.array:
        bsz, q_len, _ = hidden_states.shape

        query_states = (
            self.q_proj(hidden_states)
            .reshape(bsz, q_len, self.num_heads, self.head_dim)
            .transpose(0, 2, 1, 3)
        )
        key_states = (
            self.k_proj(hidden_states)
            .reshape(bsz, q_len, self.num_key_value_heads, self.head_dim)
            .transpose(0, 2, 1, 3)
        )
        value_states = (
            self.v_proj(hidden_states)
            .reshape(bsz, q_len, self.num_key_value_heads, self.head_dim)
            .transpose(0, 2, 1, 3)
        )

        query_states = self.rotary_emb(query_states)
        key_states = self.rotary_emb(key_states)

        if self.num_key_value_groups > 1:
            key_states = mx.repeat(key_states, self.num_key_value_groups, axis=1)
            value_states = mx.repeat(
                value_states, self.num_key_value_groups, axis=1
            )

        scale = 1.0 / math.sqrt(self.head_dim)
        try:
            attn_output = mx.fast.scaled_dot_product_attention(
                query_states, key_states, value_states,
                scale=scale, mask=attention_mask,
            )
        except Exception:
            attn_weights = (
                query_states @ key_states.transpose(0, 1, 3, 2)
            ) * scale
            if attention_mask is not None:
                attn_weights = attn_weights + attention_mask
            attn_weights = mx.softmax(attn_weights, axis=-1)
            attn_output = attn_weights @ value_states

        attn_output = attn_output.transpose(0, 2, 1, 3).reshape(
            bsz, q_len, self.num_heads * self.head_dim
        )
        return self.o_proj(attn_output)


class Qwen2DecoderLayer(nn.Module):
    def __init__(self, config: ModelArgs):
        super().__init__()
        self.self_attn = Qwen2Attention(config)
        self.mlp = Qwen2MLP(config)
        self.input_layernorm = nn.RMSNorm(
            config.hidden_size, eps=config.rms_norm_eps
        )
        self.post_attention_layernorm = nn.RMSNorm(
            config.hidden_size, eps=config.rms_norm_eps
        )

    def __call__(
        self,
        hidden_states: mx.array,
        attention_mask: Optional[mx.array] = None,
        **kwargs,
    ) -> mx.array:
        residual = hidden_states
        hidden_states = self.input_layernorm(hidden_states)
        hidden_states = self.self_attn(
            hidden_states, attention_mask=attention_mask
        )
        hidden_states = residual + hidden_states

        residual = hidden_states
        hidden_states = self.post_attention_layernorm(hidden_states)
        hidden_states = self.mlp(hidden_states)
        hidden_states = residual + hidden_states
        return hidden_states


class Qwen2Model(nn.Module):
    def __init__(self, config: ModelArgs):
        super().__init__()
        self.embed_tokens = nn.Embedding(config.vocab_size, config.hidden_size)
        self.layers = [
            Qwen2DecoderLayer(config)
            for _ in range(config.num_hidden_layers)
        ]
        self.norm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def _create_causal_mask(
        self, seq_length: int, dtype: mx.Dtype
    ) -> mx.array:
        mask = mx.tril(mx.ones((seq_length, seq_length), dtype=mx.bool_))
        mask = mx.where(mask, 0.0, -mx.inf).astype(dtype)
        return mx.expand_dims(mask, axis=(0, 1))

    def __call__(
        self,
        input_ids: mx.array,
        attention_mask: Optional[mx.array] = None,
        **kwargs,
    ) -> mx.array:
        batch_size, seq_length = input_ids.shape
        hidden_states = self.embed_tokens(input_ids)

        if attention_mask is None:
            attention_mask = self._create_causal_mask(
                seq_length, hidden_states.dtype
            )
        elif attention_mask.ndim == 2:
            padding_mask = attention_mask[:, None, None, :]
            padding_mask = mx.where(
                padding_mask == 0, -mx.inf, 0.0
            ).astype(hidden_states.dtype)
            causal_mask = self._create_causal_mask(
                seq_length, hidden_states.dtype
            )
            attention_mask = causal_mask + padding_mask

        for layer in self.layers:
            hidden_states = layer(
                hidden_states, attention_mask=attention_mask
            )

        return self.norm(hidden_states)


class Model(nn.Module):
    def __init__(self, config: ModelArgs):
        super().__init__()
        self.config = config
        self.model_type = config.model_type
        self.model = Qwen2Model(config)

    def __call__(
        self,
        input_ids: mx.array,
        attention_mask: Optional[mx.array] = None,
    ) -> BaseModelOutput:
        if input_ids.ndim != 2:
            raise ValueError(
                f"input_ids must be 2D, got shape {input_ids.shape}"
            )

        batch_size, seq_len = input_ids.shape
        if attention_mask is None:
            attention_mask = mx.ones(
                (batch_size, seq_len), dtype=mx.int32
            )

        last_hidden_state = self.model(
            input_ids, attention_mask=attention_mask
        )
        pooled_output = last_token_pool(last_hidden_state, attention_mask)
        text_embeds = normalize_embeddings(pooled_output)

        return BaseModelOutput(
            text_embeds=text_embeds,
            last_hidden_state=last_hidden_state,
        )

    def sanitize(self, weights: dict) -> dict:
        sanitized = {}
        for key, value in weights.items():
            if "lm_head.weight" in key:
                continue
            new_key = key
            if key.startswith("transformer."):
                new_key = key.replace("transformer.", "model.")
            sanitized[new_key] = value
        return sanitized
```

</details>

Then clear the Python bytecode cache:

```bash
rm -rf /Applications/oMLX.app/Contents/Python/framework-mlx-framework/lib/python3.11/site-packages/mlx_embeddings/models/__pycache__/
rm -rf /Applications/oMLX.app/Contents/Python/framework-mlx-framework/lib/python3.11/site-packages/mlx_embeddings/__pycache__/
```

### 5. Reload models in oMLX

Open the oMLX admin UI and trigger a model list reload. The jina model should now appear as type `embedding`.

### 6. Configure codescan

In `.codescan/config.ini` (or `.codescan/config`):

```ini
embedding_api=openai
embedding_url=http://localhost:8000
embedding_model=jina-code-embeddings-1.5b-mlx
embedding_dim=1536
embedding_api_key=<your-omlx-api-key>
```

Then reindex:

```bash
codescan index --force
```

### Why are these patches needed?

`jina-code-embeddings-1.5b` is built on a Qwen2 backbone fine-tuned for embeddings. It uses the same `Qwen2ForCausalLM` architecture as a regular Qwen2 chat model, but instead of generating text, it produces dense vector embeddings via last-token pooling.

oMLX and its dependency `mlx-embeddings` have native support for Qwen3-based embeddings but not Qwen2. The key architectural difference is that Qwen3 adds query/key normalization (`q_norm`/`k_norm`) in the attention layers, while Qwen2 does not. The Qwen2 embedding implementation is otherwise identical.

These patches are tracked upstream at [jundot/omlx#686](https://github.com/jundot/omlx/issues/686). Once oMLX ships native Qwen2 embedding support, the patches will no longer be needed.

### Note on updates

All patches inside `/Applications/oMLX.app/` will be overwritten when oMLX updates. After updating, test if the model works without patches first. If not, re-apply patches 3 and 4 (patch 2 persists in `~/.omlx/models/`).
