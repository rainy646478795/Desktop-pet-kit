---
name: pet-maker
description: Build a photo-cutout desktop cat pet plus the Cat Bubble overlay from real cat photos or videos. Use when a user wants to turn their own cat into a macOS desktop pet, needs guidance on what cat photos/videos to shoot, wants to minimize token usage by providing transparent PNGs or green-screen footage, or wants the full pipeline from source media to spritesheet and the Cat Bubble sidecar app.
---

# Pet Maker

Turn a real cat into a photo-cutout desktop pet and package it with the Cat Bubble overlay. The style is photo cutout, never anime or cartoon.

## Read first

Read [README.md](README.md) completely, then read [references/photo-guide.md](references/photo-guide.md) and [references/token-saving.md](references/token-saving.md). Confirm with the user whether they will supply transparent PNGs, green-screen media, or raw media before starting; this choice drives the pipeline and token cost.

## Core rules

- Photo-cutout style only: preserve real fur color, markings, and texture. Reject anime/cartoon/plush rendering.
- Full-body source is mandatory: head, body, four legs, and tail must be visible. Reject head-only or partial shots for idle/atlas work.
- Ask for the cheapest usable assets first: transparent RGBA PNGs, then green-screen media, then raw media.
- Run deterministic steps with scripts, not by eyeballing large source images repeatedly.
- Persist decisions in `run-summary.json` and a checklist; resume from conclusions, not raw media.
- Cat Bubble defaults are local and API-free. Do not enable `--live-model` unless the user explicitly asks.

## Pipeline

1. Gather assets using [references/photo-guide.md](references/photo-guide.md).
2. Slice and normalize frames to 192x208 cells.
3. Assemble the v2 atlas (8x11), despill the chroma key, and validate with the hatch-pet scripts under `~/.codex/skills/hatch-pet/scripts/`.
4. QA with contact sheets, direction sheets, and blind A/B; fix rows deterministically before regenerating imagery.
5. Package to `~/.codex/pets/<pet>/spritesheet.webp` plus `pet.json`.
6. Hand off to the Cat Bubble sidecar instructions in [../cat-bubble-skill/SKILL.md](../cat-bubble-skill/SKILL.md).

## Cost control

Follow [references/token-saving.md](references/token-saving.md). The single largest saving is user-supplied transparent cutouts; the next is batched contact-sheet review instead of opening every image.

## User prompts

Copy-paste prompts for end users live in [references/prompts.md](references/prompts.md). Surface them whenever the user asks what to type into another agent, or when they want a quick start without writing a custom prompt.
