# Notes on the GregTech component API

Everything here was read off real dumps, not documentation. Sources are the
archived dumps in `dumps/`: `001.txt` (first survey), `002.txt` (adds the super
tank), `003.txt` (adds the blast furnace). Upload links expire, so anything
worth keeping is copied there and numbered.

## `component.methods` returns false for indirect methods

The table maps method name to *whether the call is direct*. An indirect method
is present with the value `false`. So `if methods.getSensorInformation then`
is wrong — it skips exactly the machines that offer it, because
`getSensorInformation` is indirect everywhere it appears. Test presence with
`~= nil`.

This bit us once. It is silent: the feature simply never appears.

Indirect calls block until the next server tick, so reading twenty of them
takes about a second. That is why `ocdebug` reads a component's values when it
is selected rather than continuously.

## `getSensorInformation` is the useful one

Every GT block worth inspecting has it. It returns the same lines the in-game
scanner shows, and it is machine-specific in a way the generic getters are
not — a super tank still answers `getEUStored`, it just means nothing.

One convention holds everywhere:

- **Current value is `§a`, maximum is `§e`.** True for a tank's fluid, a
  buffer's charge and a furnace's progress alike, so one rule builds a gauge
  for any machine that reports one. Numbers are comma-grouped, followed by a
  unit. A line with `§a` but no `§e` is a single reading, not a gauge —
  `"Heat capacity: §a1,901§r K"`.

The text before the first number labels the reading (`Stored Items:`), or is
empty when the line opens with the number, as a tank's does.

### The first line is only sometimes the display name

Single blocks open with a `§9`-coloured name. Multiblocks open straight into
readings, so taking line one as the name labels a blast furnace
`Progress: 29 s / 37 s`. Treat line one as a name only when it has no `§a`/`§e`
pair **and** contains no digits; otherwise fall back to `getName` and tidy it.

```
tank:     {"§9Super Tank§r", "Stored Fluid:", "§6Bio Diesel§r",
           "§a42,000 L§r §e4,000,000 L§r"}
buffer:   {"§9Medium Voltage Battery Buffer§r",
           "Stored Items: §a832,768§r EU / §e832,768§r EU",
           "Average input: 0 EU/t", "Average output: 0 EU/t"}
furnace:  {"Progress: §a31§r s / §e37§r s",
           "Stored Energy: §a1,789§r EU / §e3,072§r EU",
           "Currently uses: §c480§r EU/t",
           "Max Energy Income: §e256§r EU/t(*2A) Tier: §eHV§r",
           "Problems: §c0§r Efficiency: §e100.0§r %",
           "Heat capacity: §a1,901§r K", "Pollution reduced to: §a100§r %"}
```

A machine may report several gauges; the furnace reports two.

### Sensor readings beat the generic getters

The furnace's `getWorkProgress` / `getWorkMaxProgress` say `644 / 750` in
internal ticks while its sensor says `31 s / 37 s` — the same fact, in units a
person wants. Its `getEUStored` and every steam getter return `0`, because a
multiblock's energy lives in the sensor text as `Stored Energy`. So when a
machine has sensor output, build the summary from it alone and use the numeric
getters only for machines without one, such as the diesel generator.

## Minecraft colour codes

`§` is U+00A7, two bytes in UTF-8: `\194\167`. `§r` resets; `§k`–`§o` are
formatting, not colour, and are safe to treat as a reset. The fluid name
carries its own colour (`§6` gold for Bio Diesel), which is where `ocdebug`
gets the gauge colour from — the game already knows what colour the fluid is.

## Reading values safely

Only invoke methods prefixed `get`, `is` or `has`. `setWorkAllowed` sits right
next to `getWorkProgress` in the same method list, and calling it stops the
machine. The `is`/`has` predicates (`isMachineActive`, `hasWork`,
`isWorkAllowed`) are zero-argument and safe.

Some getters still need arguments — `getInput(side)` on redstone,
`getBatteryCharge(slot)` on a buffer — and fail with
`bad arguments #1 (number expected, got no value)`. That is worth showing
rather than hiding; it tells you the method takes an argument.

## Machines seen so far

| component          | notes                                                          |
| ------------------ | -------------------------------------------------------------- |
| `gt_machine`       | covers generators, super tanks *and* multiblocks alike          |
| `gt_batterybuffer` | adds `getBatteryCharge(slot)`, `getMaxBatteryCharge`            |

`gt_machine` says nothing about what the block is. Everything seen so far —
a diesel generator, a super tank, a blast furnace — reports that one type, and
they are told apart only by their sensor text and `getName`:

| `getName`                       | what it is       | sensor text?          |
| ------------------------------- | ---------------- | --------------------- |
| `basicgenerator.diesel.tier.02` | diesel generator | none                  |
| `super.tank.tier.01`            | super tank       | name line, one gauge  |
| `multimachine.blastfurnace`     | blast furnace    | no name line, 2 gauges |

A super tank reports `getSteamStored`, `getEUStored` and friends as zero. Do
not build a summary from those.

## Pipes

This part lives in `lib/oclogistics.lua`, not in `ocgt`. Two components appear
once an adapter touches a Logistics Pipe, and they are not the same thing.

`bc_pipe` is the BuildCraft view. Plain methods, all documented, all indirect:
`getPipeType` returns `LOGISTICS`, and `hasGate(side)`, `isPipeConnected(side)`,
`isWired(colour)`, `isWireActive(colour)` each need an argument.

`logisticspipe` offers exactly one method, `getPipe`, which returns a proxy
rather than data. Its fields are one entry per method, each shaped
`{name = "getRouterId", proxy = <cycle back to the proxy>}`, plus
`type = "userdata"`. Seen in `dumps/004.txt`:

```
canAccess          getLP            getLogisticsModule   getPipeForUUID
getRouterId        getRouterUUID    getTurtleConnect     hasLogisticsModule
sendBroadcast      sendMessage      setTurtleConnect     help / helpCommand
```

`serialization.serialize` cannot touch this: it holds userdata and it is
self-referential, which is why `ocdebug` showed the bare word `table` until the
describer stopped depending on serialize.

Every entry is `table <callable, __tostring>`, confirmed in `dumps/005.txt`, so
`pipe.getRouterId()` works: the `__call` metamethod does the work and the entry
itself arrives as the argument. This is the same shape as the OpenOS `internet`
library's wrapped `close`, and it is why a `pairs()` walk alone was misleading.
`__tostring` on an entry yields its documentation.

Read live from `dumps/006.txt`:

| method | returns |
| --- | --- |
| `getRouterId()` | `1`, an integer unique per pipe, stable for the run |
| `getRouterUUID()` | `7bd7e234-e410-45de-8354-765ffb9c45bb`, stable across runs |
| `hasLogisticsModule()` | `true` |
| `getTurtleConnect()` | `false` |
| `getPipeForUUID(String)` | needs the UUID; the error names the overload |
| `getLP()` | a proxy: `getItemIdentifierBuilder`, `identify` |
| `getLogisticsModule()` | a proxy: `getFilterInventory`, `hasGui`, `isDefaultRoute`, `setDefaultRoute` |

So a pipe has two identities: `getRouterId` for a short label, `getRouterUUID`
for anything that must survive a restart. `ocgt.displayName` uses the id, since
a pipe answers no `getName`.

### Messaging

`sendMessage(computerId, ...)` and `sendBroadcast(...)` push to other computers
on the LP network and raise the events `LP_MESSAGE` and `LP_BROADCAST`. That is
a message bus between computers that needs no modem, and it is the most
interesting thing the pipe offers.

`sendMessage`, `sendBroadcast` and `setTurtleConnect` are writes and sit in the
same proxy, which is why probing is keyed on the name rather than on the entry
being callable. `canAccess` is not probed either: `can` is deliberately absent
from the readable prefixes, because `cancelCrafting` also starts with it.

## OpenSecurity keypad

`os_keypad` offers four methods and they are all writes, so `ocdump` lists them
and never calls them. From `dumps/009.txt`:

```
setDisplay(text[, color])   0 to 8 characters, colour 0 to 7, one bit per channel
setEventName(name)          the event a keypress raises
setKey(idx, text, color)    one key at a time, 1 to 2 characters
setShouldBeep(boolean)
```

**There is no getter for the key that was pressed.** Input only arrives as an
event, so `setEventName` is not optional: without it nothing is heard. The
[wiki](https://github.com/PC-Logix/OpenSecurity/wiki/Keypad) documents the event
as `name, address, button, button_label`.

Trust the dump over that wiki for the methods: it describes a table-based
`setKey` plus `setVolume`/`getVolume`, and this build has neither. `ockeypad`
reads the label straight off the event rather than calling `setKey`, so it never
has to guess how the twelve key positions are numbered.

Which bit of the 0 to 7 colour is which channel is undocumented and unverified.

## Disks, and how `install` finds one

`computer.getDeviceInfo()` describes **every** filesystem as
`description="Filesystem"`, so it cannot tell a floppy from a hard drive. Only
the sizes differ, which is a guess, not a fact. The authoritative link is the
drive: a `disk_drive` answers `isEmpty()` and `media()`, and `media()` returns
the address of the filesystem inside it. That is how `ocmkfs` knows which disk
is removable.

`computer.tmpAddress()` names the temporary filesystem, which is never an
install medium and is excluded.

OpenOS's `install` (see `bin/install.lua` and `lib/core/install_basics.lua`)
works like this:

- A candidate **source** is any mounted component filesystem that is non-empty,
  is not tmpfs, and is not the writable root.
- It reads `/.prop` at that filesystem's root and parses it with
  `load("return " .. data)`, so the file is a **Lua table literal**.
- Fields it uses: `ignore`, `label`, `fromDir`, `root`, `setlabel`, `setboot`,
  `reboot`, `noclobber`.
- It then **copies the disk's contents** onto the target, skipping `.prop`
  itself. It is a file copier, not a script runner.

So a floppy carrying `/.prop` and `/bin/ocup.lua` is offered by name and drops
`ocup` onto the target. `setboot` and `reboot` are deliberately left out of the
prop: absent means falsy, and this is dropping a program onto a working machine
rather than installing an operating system. Setting `setlabel` would rename the
target's own disk, which is also not wanted.

## OpenGlasses

`glasses` builds a scene out of widgets: `addTextLabel`, `addRect`, `addDot`,
`addQuad`, `addTriangle`, and 3D versions of most of them, plus `addItem` and
`addFloatingText`. `getBindPlayers` returned `Lucemans`, so the pairing works,
and `getObjectCount` was `0`.

**The widget methods are still unknown.** Each `add*` returns a widget object,
and those constructors do not start with `get`, `is` or `has`, so nothing calls
them and no dump has ever shown what a widget offers. Finding out means calling
one and describing the result, which `oclib.describeLines` can already do.

## Colour meanings

`§9` names a block, `§a` marks a current value, `§e` a maximum or a rating,
`§6` a fluid, and `§c` something to watch — the furnace uses it for both
`Currently uses: §c480§r EU/t` and `Problems: §c0§r`, so red does not by itself
mean a fault.

## Glasses widgets

Confirmed live with `ocglass --probe` (`dumps/` has no record of this: nothing
had ever called an `add*` method). `addTextLabel` returns a widget offering:

```
getText / setText          getPosition / setPosition
getColor / setColor        getScale / setScale
getAlpha / setAlpha        getRotation / setRotation
isVisible / setVisible     getID
```

Each method entry is a table holding `type = "userdata"`, and **its metatable is
protected**: `getmetatable` returns a string rather than the table, so `__call`
cannot be seen even though the entry is callable. Gating a probe on a visible
`__call` therefore skips every one of them and reports nothing, which is exactly
what happened on the first pass. `oclib` now simply attempts the call under
`pcall` and labels the type `table <protected metatable>`.

Argument shapes, read off a fresh widget of each kind:

| method | returns | meaning |
| --- | --- | --- |
| `getColor()` | `0.0, 0.0, 0.0` | RGB as three floats from 0 to 1, not bytes |
| `getPosition()` | `0.0, 0.0` | x, y in the wearer screen space |
| `getAlpha()` | `1.0` | float |
| `getScale()` | `2.0` | text labels only |
| `getSize()` | `0.0, 0.0` | rects only: width, height |
| `getID()` | `0` | the handle removeObject takes |

Sending 0 to 255 for colour would wash every widget out to white. A rect offers
`getSize`/`setSize` where a text label offers `getScale` and `getText`; the rest
is common to both.

**`setSize` takes height first, then width.** Measured, not read: a calibration
drawing `setSize(100, 5)` produced a vertical line and `setSize(5, 100)` a
horizontal one. Community examples show `setSize(250, 30)` as width-then-height,
which is the opposite, so trust the calibration. `ocglass` wraps this in a
`setSize(widget, width, height)` helper that swaps the arguments once, and a
check asserts a bar goes out wider than it is tall.

Whether `setPosition` is reversed the same way is not yet established.

## Screens change size under a running program

`gpu.getResolution()` is not the drawable area. A viewport can be set smaller
than the buffer, and OpenOS's own terminal measures itself with
`gpu.getViewport()`, so that is what a full-screen program should use. On this
machine both report 160x50, but an attached display need not match the screen a
program started on, and `gpu.bind` can point the card at a different screen
entirely.

A change raises **`screen_resized`**, which OpenOS's `tty` already listens for.
Any program that computes a layout once at startup will keep drawing to the old
size until it is restarted.

So every full-screen program here keeps its positional constants inside a
`layout()` function, calls it at startup, and calls it again on
`screen_resized`. `ocsweeper` additionally starts a new game when the board no
longer fits, since its board size is derived from the screen.

`core.viewport(gpu)` wraps the call and falls back to `getResolution` if a card
does not offer a viewport.

## What the OpenOS shell does to a command

Driving a machine through `occonnect` means every command passes through
`sh.execute`, and it is not bash.

- **Double quotes are removed.** `echo print("x")` writes `print(x)`, which is
  valid Lua and wrong. Lua's long-bracket strings `[[x]]` survive intact.
- **`<` and `>` are redirects wherever they appear.** `while a<b do` silently
  became `while a` plus a redirect, and the file was written with a syntax
  error rather than an error being reported.
- **`;` does not separate commands.** `echo one; echo two` fails.
- **`lua -e` is not supported.** The OpenOS `lua` program takes a file path.

This is why `occonnect` gained `:file` and `:lua`, which never reach the shell.

## What a refresh actually costs

Every indirect component call blocks until the next server tick, about 50ms.
Six machines read once each is therefore already a third of a second, and the
programs were reading each machine three times over: once for its name, once
for its readings, once for its status. That came to 36 calls, near two seconds
of every two, which is what made the dashboards lag and swallow keystrokes.

Three rules keep it down:

- **One read of the sensor per machine per refresh.** `gt.inspect` does the read
  and hands the same lines to the name, the readings and the status.
- **Read the sensor text rather than asking the machine.** A machine that has
  sensor text says in it whether it is busy: a progress gauge, or an average
  output above zero. `isMachineActive` and `hasWork` cost a tick each and are
  worse witnesses, since a battery buffer answers both yes while passing
  nothing along.
- **Names are cached.** A machine's own name cannot change while the world
  runs. Nicknames are looked up separately, so renaming one still takes effect
  at once.

That leaves the sensor and `isWorkAllowed`, which has to be asked because an
alert changes it. Six machines cost 12 calls.

## Two loop shapes that felt like lag

Sampling at the top of the event loop meant every keypress paid for a full
read of every machine before it was even looked at. Machines are now read on a
clock, and the loop only draws in between, so a key is handled at once.

Waiting for a whole round of network answers inside one call meant `ocview`
ignored the keyboard for as long as the window lasted. It broadcasts and then
reads answers as ordinary events in the loop it already has, so a satellite's
reply and a keypress are handled the same way.

## Computronics, read from its own source

The mod's wiki says of itself that its pages are usually outdated, so these
came from the `@Callback` annotations on the tile classes in
`Vexatos/Computronics`.

| component | what it offers |
| --- | --- |
| `iron_noteblock` | `playNote([instrument,] note [, volume])`. Instruments are named: harp, bd, snare, hat, bassattack, pling, bass. Anything else is refused. Volume 0 to 1. Direct, limited to 10 calls a tick. |
| `chat_box` | `say(text [, distance])`, and get/set for distance and name. The distance is capped by the server config unless the block is the creative one. |
| `speech_box` | `say(text)`, `stop()`, `isProcessing()`, `setVolume(0..1)`. Needs MaryTTS installed on the server, and `say` returns false and a reason when it is not. |
| `colorful_lamp` | `getLampColor()`, `setLampColor(0..0x7FFF)`. Five bits a channel, not eight, so a colour has to be packed. Zero is off. |
| `tape_drive` | `play stop isReady isEnd getState getPosition getSize seek read write getLabel setLabel setSpeed setVolume`. Speed 0.25 to 2, volume 0 to 1. |
| `ticket_machine` | `printTicket setDestination getDestination getSelectedTicket setSelectedTicket` and the manual-use permissions. Railcraft only. |

**The Speaker registers no component at all.** Its tile returns null for its
node and refuses every connection: it is the loudspeaker a tape drive feeds
over audio cable, not something a program calls. Sound a program chooses comes
from the note block, speech from the speech box, and words from the chat box.

## What can make a noise without anything installed

The speech box cannot, in this pack. It needs text-to-speech on the server, and
without it every `say` **returns false while the call itself succeeds**. Reading
the call as success is what kept the chat box silent behind it, so `core.setValue`
now hands back what the method returned as well as whether it raised.

What does work with nothing installed:

| block | how it sounds |
| --- | --- |
| the computer itself | `computer.beep(hz, seconds)`, always there |
| OpenSecurity alarm, `os_alarm` | a siren with a range of up to 15 blocks. Two sounds ship, klaxon1 and klaxon2. Every call is direct. It is its own loudspeaker and needs no cable. |
| Computronics iron note block | one vanilla note at a time, seven named instruments |
| Computronics chat box | words, into Minecraft chat, within a range the server config caps |

Computronics speakers carry audio from an `IAudioSource`, and the only two are
the tape drive and the speech box. Nothing else can be wired into them, so a
speaker is not a way to make a general noise.

An alarm is set while something is wrong and cleared when it is not, rather than
sounded once, which is what separates it from an announcement.

## Reading a GregTech pipe

Through a transposer you get the fluid handler's view and nothing else: how much
is in the pipe and how much fits. That is a level, not a flow. A pipe carrying a
steady flow holds a roughly constant amount, because what goes in also comes
out, so a rate worked out from the level reads near zero however much is moving
through it. What the level does tell you is net drain, which is real and worth
showing.

For the flow itself, give the pipe its own **adapter**. A GregTech block reached
that way appears as `gt_machine` and answers `getSensorInformation`. A cable in
`dumps/015-satellite-speechbox.txt` reports exactly the shape wanted:

```
Amperage: §a0§r / §e16§r A
Voltage Out: §a0§r / §e2,032§r EU/t
Avg Amperage (20t): §e0§r A
Avg Output (20t): §e0§r EU/t
```

A fluid pipe is the same kind of block, so it should report its throughput the
same way. That has not been confirmed against a real one yet.

## A name with a number in it

`looksLikeName` used to reject any sensor line containing a digit, which threw
away the name of every machine somebody had called S1 or EBF2. A reading is
either coloured, or it is a label followed by a number; anything else with
letters in it is a name.

## Why the manifest carries versions

`ocup` used to download every file in the manifest and compare it against the
copy on disk, which is one HTTPS round trip a file and most of the time it does
nothing. The manifest names the version each file declares, so the comparison
happens against the version already installed and only the files that differ are
fetched: two requests for a run with nothing to do, rather than twenty-odd.

The cost is that the manifest has to tell the truth. A file changed without its
`VERSION` moving is invisible to an update. `machine/manifest.lua` regenerates
the file from the sources, and a check in `machine/test.lua` fails when the two
have drifted apart.

A manifest line with no version still works and means "always fetch this", which
is what an older manifest does.

## Two files, so an older ocup keeps working

`ocup` before v0.15.0 reads a manifest line with `^%s*(%S+)%s*$`: one path, and
nothing else on the line. Putting the version beside the path made every line
unreadable, the manifest look empty, and the program stop, and an ocup that
cannot read the manifest cannot update itself out of the problem. Every computer
on the old version had to be fixed by hand.

So the format is two files:

- `manifest.txt` — one path a line and nothing else, for good
- `versions.txt` — the same paths with the version each file declares

`ocup` asks for `versions.txt` and falls back to `manifest.txt` when it is not
there, so a current one costs two requests and an old one keeps working.

A line carries the size in bytes as well as the version, because a version alone
is only as good as the discipline behind it. `oclogistics` was rewritten and
kept its number: every computer decided it was current, went on running the old
one, and crashed on a function that no longer existed. Bytes change whatever
anybody remembered to do.

## What ran the computer out of memory

`ocitems` used to call every readable method on a pipe's proxy and follow
whatever came back. A basic pipe survived that, since it only offers filters and
a default route. A **request** pipe does not: its proxy reaches the item network,
and building that inside a computer with a few hundred kilobytes of memory ends
the computer.

## What a request pipe answers

A request pipe offers everything a basic one does and four more:

```
getAvailableItems   getCraftableItems   getItemAmount   makeRequest
```

`getAvailableItems()` answers with one entry an item, and the entry is a proxy
rather than data: a `Pair` of `logisticspipes.utils.item.ItemIdentifier` and
`java.lang.Integer`.

| call | answers |
| --- | --- |
| `pair.getValue2()` | the count, as a number |
| `pair.getValue1()` | the ItemIdentifier, another proxy |
| `id.getName()` | `Cobblestone`, the name a person reads |
| `id.getIdName()` | `chisel:cobblestone` |
| `id.getModName()` | `chisel` |
| `id.getId()`, `id.getData()` | `2014`, `15` |

`tostring` on an ItemIdentifier gives `ItemIdentifier: chisel:Cobblestone,
2014:15`, which looks like a free name and is not: it costs more than the call
does. `tostring` on the Pair raises `java.lang.StackOverflowError`, and
`getLP().identify(pair)` answers nil.

### What each part of it costs

Measured on a live network of 1,592 items, on a computer with 1.4 MB free:

| step | time | memory |
| --- | --- | --- |
| `getAvailableItems()` | — | **950 KB**, two thirds of the computer |
| all 1,592 `getValue2()` | 0.05 s | 200 KB |
| one `getValue1().getName()` | 6 ms | ~600 bytes |

So the counts are nearly free and the names are not. Naming all 1,592 needs
about a megabyte that is not there, and asking for the whole list a second time
in one run ends the computer: it blue-screens on the second call.

**There is no `collectgarbage`.** It is not in the sandbox, so memory comes back
only under the pressure of asking for more, and never at the moment you drop
something. Dropping the whole list and printing free memory shows no change at
all; allocating hard afterwards recovers a few hundred kilobytes.

That is what shapes `lp.available`: read every count, settle the order from the
counts, drop the pairs nobody will name, and only then read the names of the 250
that will be shown. Dropping the other 1,342 first is what leaves room for those
250. The whole scan takes 1.6 seconds and ends with about 110 KB free.

### The memory does come back

That 110 KB is not what the computer has left, it is what the collector has not
got to yet. Measured over five cycles of work after a scan, free memory went
390 KB, then **1,587 KB**, and stayed there. The whole 950 KB is reclaimed.

What it needs is allocation, not time. A scan followed by three seconds of
`os.sleep` and a second scan kills the computer; a scan followed by any real
work and a second scan does not. Nothing in the sandbox asks for a collection
directly, so the only honest guard is to look at `computer.freeMemory()` and
refuse the expensive call when the room is not there yet.

## Counting one item at a time

`getItemAmount` is the way out of ever making the expensive call twice.

It wants the ItemIdentifier itself. `getItemAmount(id.getId())` and
`getItemAmount(id.getIdName())` both answer nil; the object answers. And the
object can be rebuilt out of the two numbers that name it, through the builder
on `getLP()`:

```lua
builder.setItemID(4)      -- and setItemData(0)
local id = builder.build()
proxy.getItemAmount(id)   -- 22,742, the same figure the scan read
```

Building costs nothing measurable: ten of them in under a tick, and the builder
is reused rather than asked for again. **The call itself costs 50 ms**, one
server tick, so 150 items took 7.5 seconds. That is the wrong tool for reading
everything and the right one for keeping a screen current: a few items between
draws, round and round.

So two numbers an item, written to disk, are enough to keep counting it for as
long as the program runs. That is the whole reason `ocitems` has a cache.

### Except for a tagged item

An item carrying an NBT tag cannot be named by two numbers. The network answers
**0** for it, not an error:

| item | listed | rebuilt from id and damage |
| --- | --- | --- |
| Bow | 1 | 1 |
| Slime Broadsword | 1 | 0 |
| File | 1 | 0 |

58 of the first 400 items in the network carry one, and they are tools and
weapons held one at a time. `hasTagCompound()` says which, so they are recorded
and then never counted this way — only a full read counts them. In a list sorted
by how many there are, 5 of the top 250 were tagged, which is what you would
expect of things you own exactly one of.

## How many items a machine can hold

A name does not cost a fixed amount, because most of what it costs is pairs the
collector has not reached yet, and how fast it reaches them depends on how much
room it has. Measured on the same network from two machines:

| machine | free | named | cost a name |
| --- | --- | --- | --- |
| computer, 1.4 MB | 458 KB after the list | 250 | ~1.4 KB |
| server, 3.8 MB | 2.6 MB after the list | 1,163 | ~370 bytes |

So the number is worked out rather than chosen: what is free once the list has
arrived, less what the screen needs, divided by the dearer of the two figures.
It is asked **after** the list is in memory, which is the only moment that says
what there is to work with. The small machine lands on about 220, the server on
1,163 of 1,592, and neither is tuned by hand. The server's worst moment left
1,748 KB free, which came back to 3,302 KB as soon as it did any work.

## A rate over a quarter of a minute is noise

A pass round the list takes a count a tick, so about 16 seconds for 250 items
and a minute for 1,163. Comparing a reading with the one before it therefore
measures a quarter of a minute, or less, and small movements drown in it.

A window is a minute instead: the reading that opened it is kept, and when a
minute has gone by the difference becomes the rate and a new window opens. What
is on screen is then what happened over the last minute rather than what happened
between the last two passes, and it changes once a minute rather than constantly.

Only items that are moving are worth a place. Everything else is standing still
and says nothing, so the few that are moving are the whole of what is happening
rather than the top of a long list.

## A manifest line has to stay readable by what is already installed

This has now gone wrong twice, the same way both times. A new column went into
the manifest, the ocup already on the computers could not parse the line, it
reported an empty manifest and stopped, and an ocup that cannot read the
manifest cannot update itself out of the problem.

Two rules keep it from happening again.

**A line never gains a word.** `versions.txt` is a path and exactly one word
beside it, `version:size`. An ocup that knows nothing of the size reads the
whole word as a version, finds it does not match, and fetches the file: slow,
correct, and it ends with a newer ocup installed. Anything that needs saying in
future goes inside that word, not after it.

**The parser ignores what it does not know.** `ocup` takes the first word as the
path and the second as the stamp, and does not care what follows. A stricter
parser is what caused both incidents.

Both are checked: one that every line in `versions.txt` has exactly two words,
and one that ocup installs normally from a manifest carrying columns it has
never heard of.
