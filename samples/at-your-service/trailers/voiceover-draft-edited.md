# At your service: voiceover draft 3

Draft for review. Nothing here is recorded yet. `voiceover.md` still matches
the audio in the current cut and stays as it is until this draft is approved.

About 1,220 spoken words against 760 in the recorded cut, so roughly ten
minutes at the established pace with the viewing holds. Section times are left open; measure the take first,
then retime the timeline to it.

## What changed from the recorded script

- Every section opens with a bridge line that tells the viewer where we are
  going next. No section starts cold on a command.
- The editor question gets concrete answers: repeat a change exactly, check
  that it landed, keep the recipe in git, and hand it to a script or an agent.
  The editor stays in the picture the whole time.
- The owner's own lines are back: "frosting on the cake", "in real time",
  "look at a scene, change it, play it, and read back", "Here's the thing",
  "hundreds of rocks", "This is where Swallowtail shines", "five versions",
  "same settings, same result", "known starting point", "The creative calls
  are still mine", "Nothing's moved", "plain Godot files", and the original
  sign-off.
- Search terms said out loud where they fit: Godot 4, terminal, command line,
  automation, AI agent, MCP server, Model Context Protocol, Claude Code,
  Cursor, VS Code, playtest, git.
- The intro gives a short roadmap, and the close walks back through it.
- The playtest now says out loud that the rough water was put back on for the
  test. The old script jumped from the calm plan to rough water without a word.

## Picture changes this draft needs

- 01: a card or split beat for the three reasons (repeat, check, hand off).
- 06: show `calm.json` as a file on screen before the run, with the `expect`
  line visible.
- 07: a short beat showing the rough-water value going back on before play
  (the `shader set-param ... 0.65` take already exists).
- 10: the client names on the MCP card.
- 11: a recap card listing the five stages.

## Delivery

Read only the blockquotes. Same voice, same warm, ordinary pace. An ellipsis
is a beat, not a word. Say CLI and MCP as letters, and numbers the way they
are written out here. Let the bridge lines breathe: they are where the viewer
catches up.

## Cues

### 00, At your service

Open on the title, then reveal the coast.

> Hi and welcome to Swallowtail... An automation toolkit for Godot.
>
> Over the next few minutes I'm going to set it up and show you how it can drive an open 
> editor via the terminal. Will use this cool little lighthouse on the coast scene to show
> off what you can do with this power toolset.
> We'll connect the editor, make a few edits by hand,
> turn those edits into a plan we can run, playtest the game... and then turn the 
> editor to an agent for futher refinement.

Hold the coast for 3 seconds.

### 01, Why not just use the editor?

Put the question on screen.

> So the question you are asking yourself...Why not just use the
> cli that comes with Godot?
>
> Fair question, and for one rock, you should. Drag it, adjust it, call it a day.

Beat, 2 seconds.

> Think of Swallowtail as the frosting on the cake. With the editor open,
> Swallowtail talks to it in real time. looking at the scene, adjusting it, playing it,
> and piping out the output where you can have another process acted on it, document it,
> or just capture it.
>
> That gets you a few things the include CLI doesn't give you. You can
> repeat a property change either as a single line, in a loop, or as a script. 
> You can write a script to check that it really landed or hand the job off to 
> an agent.
>
> Godot's own command line still does imports, exports, and script checks,
> and Swallowtail runs those too. What's new is reaching into the live
> editor. So... let's get it connected.

### 02, Connect the editor

Installation, status, help, scene tree, in that order.

> Getting started takes two things... Godot, and the Swallowtail binary.
>
> Open a terminal in your project folder. One install command copies the
> addon in and enables it, and launch opens the editor. The status
> tells you whether Swallowtail can reach it... and here, it can.

Hold the status result for 2 seconds.

> Now, there are over three hundred commands, and you don't have to memorize
> any of them. Ask any command for help. Here, node set shows me exactly what
> it'll accept.
>
> And scene tree shows what's actually in this scene. There's our lighthouse.

Hold the tree for 3 seconds.

> Okay. We're connected, and we know what's in here. Time to change
> something.

### 03, Move and scale the lighthouse

> Let's start with the lighthouse. I don't love where it sits. First I'll
> read its position and scale, so I know exactly where I'm starting... then
> push it across the island. Keep an eye on the tower...

Execute the move, hold 3 seconds.

> There it is. One more command and it's a bit bigger.

Hold the enlarged tower for 2 seconds.

> These edits land in the open scene, the same one you're looking at in
> Godot. So I can click that lighthouse right now and keep going in the
> inspector. Terminal or editor... use whichever's handier at the moment.

### 04, Shape the shoreline

> Next, the shoreline. It's looking a little bare, so let's add a rock. I'll
> duplicate one that's already there, give the copy a name, pull it in toward
> the shore, and scale it up so it sits right.

Hold the placed rock for 3 seconds.

> What about the water? Bump the wave amplitude... and the shoreline gets a
> little rougher.

Hold the water for 3 seconds.

> Happy with that. Save the scene.

### 05, When the work scales up

Label the examples as use cases; nothing here is a recorded run.

> So far, that's been one command at a time. And honestly, the editor could
> have done every bit of it.
>
> Here's the thing, though. What if it's hundreds of rocks instead of one? Or
> you want five versions of this coast... calm, stormy, sunset... so you can
> compare them side by side?

Hold the preset list for 2 seconds.

> In the editor, that's a lot of clicking, and you have to remember every
> value you touched. This is where Swallowtail shines. Once a sequence works,
> you write it down once and run it whenever you want.
>
> You could write your own editor script for that, and plenty of people do.
> Swallowtail gives you the commands already built, and each one tells you
> what it did.

### 06, Make it repeatable

Show `calm.json` on screen before the run.

> Let me show you what that looks like, on a small scale.
>
> This is a plan. It's a JSON file with four steps: calm the water, bring the
> daylight back, save the scene, and check that the scene is valid. If that
> check fails, the run stops and tells me which step broke.
>
> Run it... the water settles, and every step reports back.

Hold the steps and the settled water for 3 seconds.

> Now run it again.

Hold the repeated result for 3 seconds.

> Same settings, same result. That's the whole point. It's a known starting
> point I can come back to any time I'm comparing a change. And since it's
> just a file, it lives in git right next to the scene.
>
> One more thing before we play. Check runs Godot's own parser over the
> project's scripts, so a typo shows up here instead of halfway through a
> playtest. Four scripts, all clean.

Hold the check result for 2 seconds.

### 07, Playtest and inspect

Show the rough-water value going back on, then play.

> Alright. The scene's saved and the scripts are clean, so let's actually
> play it.
>
> For this test I've put the rough water back on, so we've got something to
> fix. I start the scene, ask the running game about its camera, and send it
> a movement key... and now we're down on the water, watching the game while
> it runs.

Let the movement finish, hold 3 seconds.

> Honestly... from down here, those waves are a bit much. So instead of
> guessing, I'll read the real shader value straight out of the running game.
> Point six five.

Hold the value for 2 seconds.

### 08, Try it live, then save the choice

> I can change that without stopping the game. Drop it to point one eight...
> and give the water a second.

Hold the changed water for 4 seconds.

> Yeah, that's closer. I'll read it back to be sure, check for runtime
> errors... none... and grab a frame so I can compare later.

Hold the readback and checks for 2 seconds.

> Now, one catch. That change only lives in the running game. When I stop,
> it's gone. To keep it, the same value has to go into the editor and get
> saved.
>
> And that's a nice small job to hand to an agent.

### 09, What the AI actually does

Authored staging of the recorded commands. Keep it framed as the loop, never
as a captured conversation.

> So here's the task I'd give it. Keep the calmer water, lower the sun, warm
> the light up a little, and save the scene so I can review it.
>
> An agent works the same loop we just did. It looks up the help for the
> command it needs, sets the water, moves the sun, warms the light, saves...
> and then reads the values back to check its own work.

Leave 10 seconds for the changes, the save, and the result.

> That readback is the important part. The agent sees what Godot actually
> did, so it isn't guessing. And I can see every command it ran and what it
> changed. So I review it... keep it, tweak it, or ask for another pass. The
> creative calls are still mine.

### 10, Where MCP fits

> Now, you might be wondering where MCP comes in.
>
> If your agent has a terminal, it can run the exact commands you just saw.
> MCP, the Model Context Protocol, is another way in. Clients like Claude
> Code, Cursor, or VS Code connect to Swallowtail as an MCP server, find its
> tools, and call them directly.

Hold the connection card for 2 seconds.

> Here, a client connects over standard input and output. It calls one tool
> to lower the sun for more of an evening look...

Show the sun change, hold 3 seconds.

> ...and another to read the rotation back. Same project, same editor, same
> commands underneath. Nothing's moved.

Hold the readback for 3 seconds.

### 11, Choose your workflow

Recap card, then back to the coast.

> So, let's step back for a second and look at what we did.
>
> We connected the editor, edited a scene by hand, turned those edits into a
> plan we can run again, playtested the game live, and handed the finishing
> work to an agent.
>
> You can use any piece of that on its own. Drive it yourself from the
> terminal, keep your commands in scripts, or bring in an agent when it
> helps. AI and MCP are completely optional.
>
> And the whole way through, your project is still plain Godot files.
> Scenes, scripts, resources... all of it opens in Godot just like before.

### 12, Your game. Your workflow.

End card. A clear beat before the sign-off, then let the music come up.

> There's a game you want to make. Start with a scene... and build from
> there.
>
> Swallowtail. At your service.

Leave at least 3 seconds after the sign-off for the URL and musical close.
