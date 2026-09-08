---
name: image-generation-prompting
description: Draft or refine prompts for OpenAI image generation, especially controlled product and industrial-design explorations. Use when a user wants a ready-to-run image prompt, wants to diagnose what a generated image missed, or needs a comparable multi-image design round.
---

# Prompt OpenAI Image Generation

Treat an image-generation round as a visual experiment. The prompt should make
the intended variable and the failure conditions legible rather than piling
every aspiration into one paragraph.

## Prompt Order

Use this order:

1. **Scene and format** — photographic, illustrative, diagrammatic, lighting,
   background, and on-body or off-body context.
2. **Subject** — one compact sentence naming the primary object or scene.
3. **Critical constraints** — the details most likely to fight the model's
   visual priors, stated first and in geometric or spatial language.
4. **Supporting details** — materials, dimensions, colors, and secondary
   features.
5. **Failure conditions** — explicit exclusions for likely regressions.
6. **View or panel contract** — label every requested view and say what that
   view must prove.

When a model repeatedly returns a familiar but wrong object, treat that as a
strong-prior problem. Front-load the conflicting constraint, describe the
geometry instead of relying on an adjective, and state what visible outcome
would count as failure.

## Choose One Experimental Mode

- **Exploration:** vary several axes to discover a useful vocabulary. Use at
  the beginning of a design search.
- **Controlled comparison:** vary one axis and hold every established choice
  constant. Use for decisions and iteration.

Do not mix the modes in the same contact sheet. If the sheet looks interesting
but no option can be chosen, too many variables moved at once.

## Match the View to the Question

Choose a camera projection that exposes the changing axis. Use close or macro
views for material and small geometry, strict side views for front-to-back
curvature, top-down views for overall silhouette or clearance, and paired views
when one angle gives the aesthetic read but hides the structural evidence.

For multi-panel output, label every panel and describe what must be visibly
different or preserved. Restating a critical invariant in the relevant panel
is intentional.

## Iterate Surgically

- Preserve language that already worked.
- Move a regressed constraint earlier instead of rewriting the whole prompt.
- Change one important variable per convergence round.
- Re-render a questionable option from the correct angle before rejecting it.
- Compare against the previous round and say exactly which instruction moved,
  stayed fixed, or was added.

## Output Contract

Return:

1. the complete prompt in one fenced block, ready to run;
2. a one- or two-line note naming the experimental mode, changing axis, and
   strongest prior being constrained;
3. for an iteration, one short line describing what changed from the previous
   prompt and why.

Keep commentary shorter than the prompt. The deliverable is the prompt itself.

For model parameters and generation mechanics, use the current image-generation
tool or official OpenAI documentation rather than freezing model-specific
limits in this skill.
