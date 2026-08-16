---
name: cat-bubble
description: Build, customize, and explain the Cat Bubble desktop pet overlay (formerly Atom Bubble). Use when a user wants to create, install, modify, or share the macOS cat pet with speech bubbles, mouse-action triggers, phrase banks, hotkeys, or Codex approval bubbles, or when they ask how Cat Bubble works, what it can do, or what is customizable.
---

# Cat Bubble

Cat Bubble is a standalone macOS Swift/AppKit desktop pet: a transparent always-on-top cat with idle animation, local speech bubbles, mouse-action triggers, and an optional Codex approval bubble.

## First action

Read [README.md](README.md) completely. It is the human-facing and agent-facing source of truth for behavior, customization points, run requirements, and build commands.

## Core facts

- The compiled binary runs without Codex or any AI service. Default phrases are local.
- Only `--codex` mode needs a local Codex `app-server`.
- `--live-model` is optional and only calls an OpenAI-compatible API when explicitly passed.
- Target: Apple Silicon Mac, macOS 15+, built with `swiftc -O -sdk ... -target arm64-apple-macosx15.0 -framework AppKit -framework ApplicationServices`.

## Customization map

Keep changes small and scoped:

- Phrases and persona: `phrases.json`
- Bubble interval: `--interval-min` / `--interval-max` (seconds)
- Animation timing: `startIdleLoop` frame interval in `src/atom_bubble.swift`
- Action triggers: `PetView` mouse callbacks and the menu items in `Controller`
- Hotkeys: global key monitor keyCodes in `Controller`
- Pet art: replace PNGs under `assets/idle/`, `assets/look/`, `assets/waving/`, `assets/jumping/`, `assets/running-left/`, `assets/running-right/`

## Share preparation

Before publishing, replace personal phrases and pet assets, add a LICENSE, and keep the README DIY table so other agents can customize the project.
