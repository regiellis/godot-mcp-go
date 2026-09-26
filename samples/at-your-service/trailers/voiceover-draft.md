# At your service: voiceover draft 4

Recorded as take 4 (`narration-take4-master.json`, `audio/take4/`) for a
listening cut; still under review. `voiceover.md` is the earlier polished cut's script.

## How this one is written

It's talk over the screen. The viewer is watching something happen, and the
voice reacts to it: "watch the lighthouse", "there", "yeah, that's rough".
No line stops to define the product. The reasons to use it come up where the
picture makes them obvious, in the words you'd say out loud.

The fragments are on purpose. Don't smooth them into full sentences when
recording. An ellipsis is a beat. Say CLI and MCP as letters.

Most of the running time is now picture, so holds matter more than word
count. Measure the take, then time each hold to what's on screen; the
directions below are minimums.

## Picture changes this draft needs

- 01: a quick beat of one rock, then a field of rocks, for "fifty rocks".
- 06: `calm.json` open on screen before the run.
- 07: the rough water going back on before play (the `0.65` take exists).
- 10: the client names on the MCP card.
- 11: a recap card with the five stages.

## Cues

### 00, At your service

Title, then the coast.

> So... this is Swallowtail.
>
> I've got Godot open here, with this little stretch of coast... and I'm going
> to do most of this from the terminal.
>
> I'll move some things around, change a few values, run the game... even
> change stuff while it's running.
>
> And Godot stays open the whole time.
>
> So... let me show you.

### 01, Why not just use the editor?

> Now, you might be thinking... why not just do this in the editor?
>
> And for one rock? Yeah. Just drag it.

Beat, 2 seconds.

> But if I need to do it again... or do the same thing to fifty rocks...
> that's different.
>
> Here I can do it once, save what I did, and just run it again. And every
> command tells me what actually happened, so I'm not eyeballing it.
>
> Okay. Let's get it hooked up.

### 02, Connect the editor

> So I've got Godot, and I've got the Swallowtail binary.
>
> I'm in the project folder. Install puts the addon in and turns it on...
> launch opens the editor... and status... yep. It can see it.

Hold the status result, 2 seconds.

> There are a lot of commands. Over three hundred. I don't remember them
> either.
>
> So I just ask. Node set, help... and it tells me what it wants.
>
> Scene tree... that's everything in the scene. And there's the lighthouse.

Hold the tree, 3 seconds.

> Okay, we're in. Let's change something.

### 03, Move and scale the lighthouse

> Watch the lighthouse.
>
> First... where is it right now? Okay. That's the position, that's the
> scale.
>
> I'm going to move it over here.

The move. Hold 3 seconds.

> There.
>
> And a little bigger.

The scale. Hold 2 seconds.

> And that's the actual scene. If I click it in Godot... same object. I can
> keep going in the inspector if I want.

### 04, Shape the shoreline

> Now the shore looks a bit empty.
>
> I'll copy one of these rocks... give it a name... move it in... and make it
> bigger.

Hold the placed rock, 3 seconds.

> That's better.
>
> And the water... let's turn the waves up.

Hold the water, 3 seconds.

> Yeah, that's rough. Okay. Save.

### 05, When the work scales up

Examples only. Nothing here is a recorded run.

> So that's all one command at a time. And honestly, I could've done all of
> that by hand.
>
> But say it's not one rock. Say it's a few hundred.
>
> Or I want five versions of this coast... calm, stormy, sunset... and I want
> to flip between them.

Hold the preset list, 2 seconds.

> Clicking through that every time? No thanks.
>
> This is where Swallowtail really shines.

### 06, Make it repeatable

`calm.json` on screen first.

> So here's a plan. It's just a JSON file.
>
> Four steps. Calm the water, bring the daylight back, save, and check the
> scene's valid. If that check fails, it stops and tells me where.
>
> Let's run it.

The run. Hold 3 seconds.

> Water's calm... and every step came back.
>
> Run it again...

The second run. Hold 3 seconds.

> Same result. That's kind of the point. I can always get back to this.
>
> And it's a file, so it goes in git with everything else.
>
> One more thing before we play. Check... that runs Godot's own script
> checker over the project. Four scripts... all good.

Hold the check result, 2 seconds.

### 07, Playtest and inspect

> Okay. Let's play it.
>
> I put the rough water back on first... so there's something to fix.

The `0.65` beat, then play.

> Start the scene... check the camera... and move forward a bit.

Let the movement finish. Hold 3 seconds.

> Hmm. From down here, that's a lot of wave.
>
> Let me ask the game what it's actually set to... point six five.

Hold the value, 2 seconds.

### 08, Try it live, then save the choice

> Let's drop it. Point one eight... while it's running.

Hold the changed water, 4 seconds.

> Yeah. That's more like it.
>
> Read it back... point one eight. Any errors? None. And I'll grab a frame to
> compare later.

Hold the checks, 2 seconds.

> Now... the catch. That's only in the running game. When I stop, it's gone.
>
> So that value has to go into the scene, and get saved.
>
> Which is a nice little job for an agent.

### 09, What the AI actually does

Authored staging of the recorded commands. Keep it as "here's what it does",
never as a captured conversation.

> So I'd tell it something like... keep the calm water, lower the sun, warm the
> light up, and save it so I can take a look.
>
> And it does the same thing I just did. Looks up the command... sets the
> water... moves the sun... warms it up... saves.

Leave 10 seconds for the changes, the save, and the result.

> Then it reads it all back, so it knows it worked. It's not guessing.
>
> And I can see every command it ran. Don't like it? I change it, or ask
> again.
>
> The creative calls are still mine.

### 10, Where MCP fits

> Now... MCP.
>
> If your agent has a terminal, it can just use these same commands. You
> don't need MCP for that.
>
> MCP is for tools like Claude Code, Cursor, VS Code. They connect, see the
> tools, and call them.

Hold the connection card, 2 seconds.

> Here's one connecting. It lowers the sun...

The sun change. Hold 3 seconds.

> ...and reads it back.
>
> Same editor. Same commands underneath. Nothing's moved.

Hold the readback, 3 seconds.

### 11, Choose your workflow

Recap card, then the coast.

> So, quick recap.
>
> We hooked up the editor... moved some stuff around... saved it as a plan...
> played the game and fixed it live... and handed the last bit to an agent.
>
> Use whatever part you want. Just the terminal... scripts... an agent. The AI
> part's completely optional.
>
> And it's all still plain Godot files. Open it without Swallowtail and it's
> just your project.

### 12, Your game. Your workflow.

End card. A beat before the sign-off, then let the music come up.

> So... there's a game you want to make.
>
> Start with a scene... and build from there.
>
> Swallowtail. At your service.

Leave at least 3 seconds after the sign-off for the URL and musical close.
