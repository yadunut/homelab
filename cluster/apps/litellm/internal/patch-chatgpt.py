"""Preserve caller streaming preference for ChatGPT in LiteLLM v1.101.0.

ChatGPT requires stream=true upstream even when the caller wants JSON. Promoting
that upstream flag to the caller's flag bypasses ChatGPT's existing SSE-to-JSON
parser and breaks non-streaming Responses and the Chat Completions bridge.
Patch both sync and async handlers; fail closed if a new image changes the code.
"""

from pathlib import Path
import litellm

source = Path(litellm.__file__).parent / "llms/custom_httpx/llm_http_handler.py"
original = source.read_text()
before = 'stream = bool(stream or data.get("stream"))'
after = (
    'stream = bool(stream or '
    '(data.get("stream") and custom_llm_provider != "chatgpt"))'
)
if original.count(before) != 2:
    raise RuntimeError("LiteLLM HTTP handler changed; review the ChatGPT patch")
patched = original.replace(before, after)
compile(patched, str(source), "exec")
Path("/patched/llm_http_handler.py").write_text(patched)
print("Applied ChatGPT stream preference compatibility patch")
