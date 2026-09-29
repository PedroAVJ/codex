---
name: image-generation
description: Generate or edit raster images with OpenAI image generation from Claude Code on this Mac, through the ChatGPT-authenticated Codex CLI (default) or the OpenAI Image API (explicit fallback). Use when the user asks Claude to create, render, mock up, restyle, or edit a photo, illustration, product or industrial-design concept, texture, sprite, or other bitmap image, or to run a comparable multi-image design round.
---

# Generate Images With OpenAI

Claude has no native image generator. On this Mac, OpenAI image generation is
reached through the Codex CLI, whose built-in `image_gen` tool runs on the
user's ChatGPT sign-in, or through the OpenAI Image API, which needs API
credits. Use the Codex path unless the user explicitly asks for the API or for
a control only the API has.

Do not use this skill when the deliverable is better made natively: SVG or
vector icons, logos that must match an existing vector system, diagrams,
charts, or UI built in HTML/CSS/canvas.

## 1. Check the route

```bash
codex login status                          # expect "Logged in using ChatGPT"
codex features list | grep image_generation # expect "stable  true"
```

If either check fails, report it. Do not start or restart a login flow.

## 2. Generate or edit through Codex (default)

Run one non-interactive Codex turn per image. Use a task scratch directory as
the working root and a read-only sandbox, because Codex only needs to call its
image tool:

```bash
OUT="<scratch>/imagegen"; mkdir -p "$OUT"
codex exec --skip-git-repo-check -s read-only -C "$OUT" --json \
  -o "$OUT/last-message.txt" \
  -- "Use your built-in image generation tool to generate exactly one image. \
Do not run shell commands. Prompt: <final prompt>" \
  < /dev/null > "$OUT/run.jsonl"
```

- **Edit or reference images:** add `--image <file>` (repeatable) and describe
  each image's role in the prompt: edit target, style reference, or insert.
  Keep `--` before the prompt, because `--image` accepts several values and
  otherwise swallows it. Name the invariants: "change only X; keep Y unchanged".
- **Find the output:** read `thread_id` from the first JSONL line
  (`thread.started`). Codex writes the image to
  `~/.codex/generated_images/<thread_id>/exec-<call-id>.png`. The image call is
  not emitted as a JSONL item, so list that directory rather than parsing the
  agent message.
- **Timing:** a run takes about one to two minutes. For several distinct images
  or variants, start one run per image in the background and collect each
  thread's directory; do not ask one run for many images.
- **Errors on stderr:** Codex logs unrelated MCP connection errors there. Judge
  success by exit status and the presence of the new PNG.

### Settings through Codex

The built-in tool takes no size, quality, format, or background parameters.
State orientation or aspect ratio ("square", "16:9 landscape", "tall 9:16
portrait") and any need for a transparent background in the prompt, then check
the result:

```bash
sips -g pixelWidth -g pixelHeight "<image>"
```

Outputs are PNG at roughly 1.5 megapixels: a square request returned 1254x1254
and a 16:9 request 1672x941. If exact pixel dimensions matter,
resize or crop the delivered copy locally (`sips -z <h> <w>`, `sips -c <h> <w>`)
or use the API route with an explicit `--size`.

## 3. OpenAI Image API (explicit fallback)

Use only when the user asks for the API, a specific model, exact size or
quality, masks, `n` variants of one prompt, or native transparency. The Codex
installation ships a maintained CLI for it; use it instead of writing a runner:

```bash
IMAGE_GEN="$HOME/.codex/skills/.system/imagegen/scripts/image_gen.py"
python3 "$IMAGE_GEN" generate --help   # also: edit, generate-batch; --dry-run needs no key
```

- The key is exported in the user's interactive `~/.zshrc` and is absent from
  Claude's non-interactive shell. Load it for the one command without printing
  it: `OPENAI_API_KEY="$(zsh -ic 'print -rn -- $OPENAI_API_KEY' 2>/dev/null)" python3 "$IMAGE_GEN" ...`.
  Never echo, log, or ask for the key.
- Default model is `gpt-image-2`: `--quality low|medium|high|auto`, `--size auto`
  or `WIDTHxHEIGHT` (edges multiples of 16, max edge 3840, ratio at most 3:1,
  0.66 to 8.3 megapixels; common: `1024x1024`, `1536x1024`, `1024x1536`,
  `2048x1152`, `3840x2160`). Use `low` for drafts, `medium` or `high` for finals
  and dense text.
- `gpt-image-2` rejects `--background transparent` and `--input-fidelity`. Ask
  before switching to `gpt-image-1.5` for native transparency; never downgrade
  models silently.
- Pass `--no-augment` when the prompt is already final, and `--out` to choose
  the output path.
- A `429 insufficient_quota` / `credit_balance_exhausted` error means the API
  organization has no credits. Report it and offer the Codex route; do not
  retry.

## 4. Write the prompt

Order the prompt as: scene and format; one-sentence subject; critical
constraints that fight the model's visual priors, stated first and in geometric
or spatial terms; supporting details (materials, colors, dimensions); explicit
failure conditions; and, for multi-panel output, a label and purpose for every
view. Quote any in-image text verbatim.

- Preserve a specific user prompt; only structure it. Add detail to a generic
  prompt only when it materially helps, never unrequested brands, characters,
  or copy.
- For design rounds, choose one mode per sheet: **exploration** (vary several
  axes) or **controlled comparison** (vary one axis, hold the rest). Pick the
  camera view that exposes the changing axis.
- Iterate surgically: keep language that worked, move a regressed constraint
  earlier, change one variable per round, and repeat edit invariants every time.

## 5. Inspect and deliver

1. Read each output image before presenting it and check subject, composition,
   text accuracy, aspect, and the stated failure conditions. Regenerate with one
   targeted change when it misses.
2. Copy every image the user should see into the current workspace with a
   descriptive name; never overwrite an existing file unless asked (use
   `-v2`-style siblings). Do not leave a project asset only under
   `~/.codex/generated_images`.
3. Link each image once as a clickable absolute Markdown path, for example
   `[Option 1](</absolute/workspace/path/option-1.png>)`; do not rely on inline
   tool rendering alone.
4. Report the route used (Codex or API, with model and settings for the API),
   the final prompt, and anything that missed.
