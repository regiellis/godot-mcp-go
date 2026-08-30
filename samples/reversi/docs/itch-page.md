# itch.io page copy

Paste-ready text for the itch.io project page. Not shipped with the game: this
file is here so the store copy lives with the thing it describes and can be
edited in review like anything else.

The page itself is configured in itch's editor. What this file covers is the
wording.

---

## Title

```
Reversi
```

## Short description (the one line under the title, 120 characters or fewer)

```
The classic board game, drawn entirely in code. Built by AI agents driving a live Godot editor.
```

That is 95 characters.

## Classification and kind

- **Kind of project:** HTML
- **Classification:** Game
- **Release status:** Released
- **Pricing:** No payments (free)

## Embed options

- **Kind of embed:** Embed in page
- **Viewport:** 1280 x 720. The game is authored at 2560 by 1440 and scales to
  whatever it is given, so this is a frame size rather than a resolution.
- **Fullscreen button:** enabled. Worth it at this aspect ratio.
- **Mobile friendly:** off. It is a mouse and keyboard game.

## Genre and tags

- **Genre:** Strategy
- **Tags:** `board-game`, `reversi`, `othello`, `godot`, `open-source`,
  `source-available`, `ai`, `no-sprites`, `singleplayer`, `local-multiplayer`

## Description

```
Reversi, the classic eight by eight board game. Black moves first, you place a disc
to outflank a line of your opponent's, and every disc you trap flips to your colour.
Play the computer at one of three depths, or two people at one keyboard.

There is not one sprite in this project. The board, the discs, the buttons, the
sliders, the panels, the notification stack and the screen transition are all drawn
in code, out of polygons and text. It runs at any resolution because there is no
bitmap to go soft.


WHAT THIS ACTUALLY IS

A demonstration. The whole game was built by AI agents driving a live Godot editor
through godot-mcp, a tool that gives an agent the real development loop: build, run,
play, observe, debug, fix, verify.

The brief came from a video demonstrating a different tool. This is the same brief
answered with godot-mcp, so both results sit in the open and can be judged on what
they produced rather than on anybody's claims.

This is NOT an argument for generating games from a single prompt, and it is not a
case for making games at volume.

One prompt produced the brief. Everything after that took direction. The first build
looked finished and was not: it carried spacing and overlap faults on every screen, a
drop shadow that made small text read as doubled, and a title screen that clicked at
the player once a second for as long as it was open. A person found all of it.

It also worked because Reversi is a solved problem. The rules are fixed and
published, the board is eight by eight, and the interface conventions are decades
old. Nothing here had to be invented, prototyped, or found by playing the thing until
it felt right. A brief for a game that does not exist yet, where the mechanic has to
be discovered by iterating on it, is a different job, and one prompt does not touch
it.

godot-mcp is a tool. It belongs alongside the rest of a Godot workflow rather than in
place of it: source control, review, playtesting, and someone with the judgement to
decide when a thing is actually done.


HOW TO PLAY

Click a highlighted cell to place a disc. A move has to outflank at least one of your
opponent's discs, in any of the eight directions. When neither player can move, the
larger count wins. Corners cannot be flipped once taken, which is why they are worth
more than the count on the board says.

Escape opens the pause menu. Arrow keys and Enter drive every menu.


THE SOURCE

Everything is MIT licensed and readable:
https://github.com/regiellis/godot-reversi

It is a teaching artifact rather than a product. It is not maintained as a game and
takes no feature requests. The licence is MIT because the point is for people to read
it, learn from it, and reuse the techniques freely.

The tool that built it: https://github.com/regiellis/godot-mcp-go


CREDITS

None of the people credited here are associated with this project and none of them
have endorsed it. Their work is used under licences that permit reuse. A CC0 release,
an OFL font or an MIT kit grants permission to use the work. It says nothing about
their view of AI tools, of AI in games, or of this demonstration.

The look and feel come from the Liquid UI Kit for Godot by Miisan, which is where the
idea of drawing every widget in _draw() comes from. Each property stays a float a
tween can move, which is why a button can squash on press and a score counter can
roll, punch and settle. Re-implemented here rather than vendored, but the thinking is
theirs:
https://miisan.itch.io/godot-4-ui

Sound effects by Kenney, released under CC0: https://kenney.nl
Type is Bungee by David Jonathan Ross, under the SIL Open Font License 1.1.
Built with Godot 4.7.
```

## Screenshots to upload

From `media/`, in this order. itch shows the first as the cover thumbnail in
listings, so the match screen leads.

1. `game.png` (the match, with the panel column)
2. `title.png`
3. `how-to-play.png`
4. `setup.png`
5. `settings.png`
6. `result.png`

## Cover image

`media/cover.png`, already at itch's 630 x 500. It was rendered by Godot from the
game's own `Design` tokens and its real Bungee face rather than drawn separately,
so it cannot drift from how the game looks. Upload it as the cover.

The 16:9 screenshots are all the wrong shape for this slot, which is why the
cover is its own image rather than a crop.

## Before the first push

`butler` needs the project to exist. Create it in itch's editor, set the kind to
HTML, then take an API key from https://itch.io/user/settings/api-keys and add
it to the repository as the secret `BUTLER_API_KEY`.

The workflow pushes to `paperenigma/reversi:html`. If the project ends up at a
different URL slug, change `ITCH_TARGET` in `.github/workflows/pages.yml` to
match, or the push will fail with a project-not-found error.
