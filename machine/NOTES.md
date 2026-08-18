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
