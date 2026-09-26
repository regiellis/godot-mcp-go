# At your service: voiceover script

Recorded revision after the hand edits in `8237786` and `60a7a06`.
The hand-written additions were editorial notes; their ideas were developed
into complete narration and transitions between demonstrations.

The assembled film is 416.73 seconds at 30 fps. Section times below
are rounded for reading; `narration-revision.json` preserves the precise
paragraph/word placements, and the Godot timeline carries the matching picture.
The continuous PSONA performance runs at their natural speed, with no tempo adjustment.

## Delivery and timing

Read only the blockquotes. Directions and screen beats are not spoken.
Use a warm, ordinary speaking voice. Say the connecting words; do not read
command syntax as a list of disconnected nouns. Say CLI and MCP as letters.

Record one continuous performance, then cut at paragraph boundaries. Leave the
holds silent over the music. Show a command before explaining its result,
then let the result remain visible. A pause in the recording is not enough
if the picture has already moved on to the next command.

For future recordings, measure the takes before locking the timeline. Extend
a shot or trim the copy if needed; do not speed up the voice to fit a window.

## Cues

### 00, At your service — 0:00 to 0:22

Easy and warm. Open on the title, then reveal the coast.

> Hey, welcome to Swallowtail, an automation toolkit for Godot. Let's make a
> few changes to this stretch of coast. I'll show you how to connect the
> editor, automate a workflow, and bring an AI agent into the process.

Hold the coast for 3 seconds before the next thought.

### 01, Why not just use the editor? — 0:22 to 1:01

Put the question on screen. Answer it directly before the demo.

> There's an obvious question: why not just use the editor?
> If I'm moving one rock, I probably would. It's easy to place it by eye.
> Swallowtail becomes useful when I want to repeat that work, try several
> variations, or let an agent help with the changes.

Keep the scene visible; allow a 2-second beat.

> Godot's own command line already handles imports, scripts, and exports.
> Swallowtail also lets us reach into the editor we're working in. Let's
> connect it.

### 02, Connect the editor — 1:01 to 1:38

Show installation, connection status, help, and scene tree in that order.

> I've installed Godot and the Swallowtail binary. Now I'll open a terminal in the
> project folder. From here, I can install and enable the addon, then launch
> the editor. The status command tells me whether the connection is ready.

Hold the status result for 2 seconds.

> Whenever I need an option, I can ask for help. Here, node set explains how
> to change a property. Next, I'll read the scene tree to find our lighthouse.

Hold the tree for 3 seconds so the viewer can find the lighthouse.

### 03, Move and scale the lighthouse — 1:38 to 2:09

Read the transform, show the move, then show the scale change separately.

> Let's give the lighthouse a better spot. I'll read its position and scale
> first, so I know where I'm starting. Then I'll move it across the island.
> Watch the tower...

Execute the move and hold its result for 3 seconds.

> There we go. I'll make it a little bigger, too. We're changing the open
> scene, so I can select that same lighthouse in Godot and carry on in the
> inspector.

Hold the enlarged tower for 2 seconds.

### 04, Shape the shoreline — 2:09 to 2:40

Keep each operation visible as it is named. Avoid a cut during the rock move.

> The shoreline could use another rock. I'll duplicate this one, name the
> copy, and bring it closer to shore. A small change to its scale helps it
> fit.

Hold the placed rock for 3 seconds.

> Let's give the water more movement. I'll increase the wave amplitude. Watch
> the difference along the shore.

Hold the water for 3 seconds.

> I'll save that and see how it feels in the game.

### 05, When the work scales up — 2:40 to 3:16

Label the larger example as a use case, not a recording of a hundred-object
operation. Return to the editor question.

> So far, these are small edits. But imagine adjusting hundreds of rocks, or
> comparing five versions of this coast with different water and lighting.
> That's when a repeatable set of commands starts to save work. I can choose
> the settings once and apply them again.

Hold a list of example presets for 2 seconds; do not invent results.

> You could write a Godot script for that, too. Swallowtail gives you ready-made commands to build on, whether you're writing the automation yourself or
> asking an agent to help.

### 06, Make it repeatable — 3:16 to 3:51

Show the real `calm.json` plan and its recorded output.

> Here's what that looks like. This plan brings back the calm water and
> daylight, saves the scene, and checks that it's valid. I'll run it now.

Show the steps and the settled water. Hold for 3 seconds.

> Let's run the same plan again.

Keep the repeated result visible for 3 seconds.

> We're back at the same settings. This plan sets specific values, so I can
> return to this version whenever I need a comparison. I'll check the scripts
> before we play it.

Hold the script check result for 2 seconds.

### 07, Playtest and inspect — 3:51 to 4:21

Show the running game, camera inspection, movement input, and shader read.

> Let's see the coast from inside the game. I'll start the scene, check the
> active camera, and send a movement key to get a closer look.

Let the movement finish and hold the game for 3 seconds.

> From down here, the waves feel a bit strong. I'll read the shader value from
> the running game. It's set to point six five. Let's try bringing that down.

Hold the value for 2 seconds before changing it.

### 08, Try it live, then save the choice — 4:21 to 4:56

Separate the runtime change from the later editor save.

> I'll set the amplitude to point one eight. Watch the water for a moment...

Hold the changed water for 4 seconds before the readback.

> That feels closer. I'll read the value back to confirm it, check for runtime
> errors, and capture a frame to compare later.

Hold the readback and checks for 2 seconds.

> This change belongs to the running game. To keep it, I need to apply the
> same value in the editor and save. That's a useful task to hand to an agent.

The following agent section demonstrates applying and saving that choice.

### 09, What the AI actually does — 4:56 to 5:43

Show the task, discovered help, commands, and readback. Use the existing
authored demonstration; do not imply its cards are a captured AI conversation.

> I can ask an AI agent to keep the calmer water, lower the sun, and warm the
> light, then save the scene for review. Here's the workflow: inspect the
> project, look up the commands, apply the changes, and read the results back.

Leave 10 seconds for the water and lighting changes, the save, and the
result to remain visible before the review paragraph begins.

> The agent gets feedback from Godot as it works, and I can check both the
> commands and the scene. If something isn't right, I can adjust it or ask for
> another pass. I still decide how this coast should look.

### 10, Where MCP fits — 5:43 to 6:27

Show the connection, then the existing real tool call and readback.

> An agent with terminal access can use those same CLI commands. MCP, or Model
> Context Protocol, gives AI clients another way to discover and call
> Swallowtail's tools. Both routes reach the same operations in Godot.

Hold the connection card for 2 seconds.

> Here, the client connects to Swallowtail through standard input and output.
> It calls a tool to lower the sun, and we can watch the scene change.

Show the sun change and hold for 3 seconds.

> Then it reads the sun's rotation back, so we can check that the change took
> effect.

Hold the readback for 3 seconds.

### 11, Choose your workflow — 6:27 to 6:47

Return to the coast and the three ways to work: editor, CLI, optional agent.

> You can use Swallowtail yourself, reuse your commands in scripts, or connect
> an agent when it helps. AI and MCP are optional. And throughout that
> workflow, you're working with ordinary Godot scenes and scripts.

### 12, Your game. Your workflow. — 6:47 to 6:57

End card. Warm, with room for the sign-off.

> Start with a scene... and see where it takes you.
>
> Swallowtail is at your service.

Leave at least 3 seconds after the sign-off for the URL and musical close.
