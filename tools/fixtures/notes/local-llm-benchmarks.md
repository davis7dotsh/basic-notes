# local llm on the mac studio

M2 Ultra 192GB. tokens/s generation, 4-bit unless noted

| model | runtime | tok/s | notes |
|---|---|---|---|
| llama 3.3 70B | ollama | 11 | usable for chat, slow for agents |
| qwen 2.5 coder 32B | mlx | 24 | best for code locally |
| gemma 3 27B | ollama | 22 | |
| nomic-embed-text | ollama | — | 1k chunks/s, fine for notes embeddings |

```bash
ollama pull qwen2.5-coder:32b
OLLAMA_HOST=0.0.0.0:11434 ollama serve
mlx_lm.generate --model mlx-community/Qwen2.5-Coder-32B-Instruct-4bit --prompt "..."
```
- for the notes app, use a tiny embedding model bundled in-app (bge-small, 384 dims), not ollama
