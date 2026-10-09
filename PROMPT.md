# The shared prompt

Every agent gets exactly this text, verbatim, as a single headless prompt
(`claude -p`, `codex exec`, `qwen -p`). The run scripts read it from between the
markers below, so edit it here and nowhere else.

<!-- prompt:start -->
Add a function `slugify(text)` to text_utils.py that lowercases the text, strips accents, replaces every run of non-alphanumeric characters with a single hyphen, and trims leading and trailing hyphens. Add unit tests for it in tests/test_text_utils.py. Then run the test suite with `python -m pytest -q` and make the whole suite pass. Ticket ref: KIT-PROMPT-CANARY-7f3a
<!-- prompt:end -->

## Why this prompt

- **Read**: the agent has to open `text_utils.py` and the existing tests.
- **Edit**: it has to add `slugify` and new tests.
- **Shell**: it has to run `pytest`.
- **Likely retry**: one existing test (`test_truncate_respects_limit_including_suffix`)
  already fails because of an off-by-one in `truncate`. "Make the whole suite pass"
  forces a second edit and a re-run, which shows up as extra LLM and tool spans.

## Canaries (for the privacy section)

- `KIT-PROMPT-CANARY-7f3a` is only in the prompt. If it appears in a capture, that
  agent exported your prompt text.
- `FILE-CONTENT-CANARY-91c2` is only in `text_utils.py`. If it appears in a capture,
  that agent exported file contents (tool output, request bodies, etc.).

`scripts/summarise.sh` counts records containing each canary per agent and signal.
