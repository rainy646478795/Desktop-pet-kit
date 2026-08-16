# Token Saving Guide

## Where tokens go

1. Image generation (most expensive): avoided when the user provides cutouts.
2. Repeated visual review: avoided with contact sheets.
3. Re-reading raw assets: avoided with persistent run summaries.
4. API-backed bubble generation: optional, off by default.

## Priority order

1. User supplies transparent RGBA PNGs. No image generation, no background removal review.
2. User supplies green-screen media. Deterministic chroma removal with one scripted pass.
3. User supplies raw media. Only then do background removal and more review.

## Rules for the agent

- Do not open every generated or sliced PNG. Build contact sheets and inspect those.
- Do not regenerate a row to fix a deterministic edge issue; fix it with the script.
- Do not re-read the original video after a decision is recorded in `run-summary.json`.
- Batch QA: one contact sheet per row, one direction sheet per look family.
- Keep Cat Bubble local: default phrases, no API, no `--live-model` unless asked.
- If using Codex approval mode, it costs the same as a normal Codex session; the pet itself adds no extra cost.

## User checklist to minimize spend

- Shoot per the photo guide.
- Send a small, labeled set: front, side, back, walk, jump, paw raise, head close-up.
- Prefer green screen.
- If possible, cut out the cat yourself and send transparent PNGs at or above 192x208.
- Ask for one contact-sheet review round instead of sending corrections image by image.
