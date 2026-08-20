# Open Computers Programs in GTNH

Lua programs for the OpenComputers mod in GregTech New Horizons.

https://ocdoc.cil.li/api:internet

## Programs

| program     | what it does                                                          |
| ----------- | --------------------------------------------------------------------- |
| `ocup`      | fetches `manifest.txt`, then installs the programs this computer chose |
| `ocwatch`   | fixed dashboard for chosen machines, with thresholds that can act      |
| `ocview`    | every satellite on the network at once, on a tablet                    |
| `ocserve`   | answers for the machines it watches, with nobody looking at its screen  |
| `ocping`    | whether the network works, at either layer                             |
| `ocdebug`   | live on-screen browser for components, their methods and values        |
| `ocdump`    | uploads a full system dump as an unlisted paste, to share for support  |
| `occonnect` | lets someone off the machine run commands on it, over HTTPS            |
| `ockeypad`  | a PIN lock on an OpenSecurity keypad                                   |
| `ocmkfs`    | flashes a floppy with the programs you pick, for a computer with no net |
| `ocsweeper` | minesweeper, up to 21x21                                               |
| `ocitems`   | everything the Logistics Pipes network holds, items and fluids alike   |

## occonnect

OpenComputers cannot open a TLS socket, so MQTT over `wss://` is out of reach.
`occonnect` uses [ntfy](https://ntfy.sh) instead, which is plain HTTPS request
and response, the one transport this machine already does reliably. Nothing
needs hosting; `--server` points it at your own ntfy if you would rather.

```
occonnect            connect and wait for commands
occonnect --once     one poll, for checking it works
occonnect --reset    issue a new pairing code
```

The topic comes from half the computer address, so it is not something anyone
stumbles onto. The pairing code is generated on the machine, shown on its
screen, and travels inside each command where `occonnect` checks it, so a topic
being public does not let anyone run anything. Commands are not restricted:
whatever arrives with the right code goes to the shell.

```
send     curl -d "<code> ocup"  https://ntfy.sh/<topic>
read     curl -s "https://ntfy.sh/<topic>-out/raw?poll=1"
```

Whatever is already in the topic when `occonnect` starts is treated as history,
so restarting cannot replay a command sent hours ago.
## The network

Every machine here talks over [Minitel](https://github.com/ShadowKatStudios/OC-Minitel),
which is a daemon owning the modems and a library that turns calls into signals
for it. A machine is a name rather than half a card address, and a satellite is
reachable through whatever computers sit between here and there rather than only
one that happens to be in wireless range.

This replaced a raw modem broadcast, and the two do not understand each other.
Every machine has to be updated and restarted; one that is missed goes quiet
rather than degrading.

A packet is six parts: an id, a type, the destination hostname, the sender, a
virtual port, and the data. The daemon drops any id it has seen in the last
thirty seconds, remembers which card each hostname was last heard through, and
forwards anything not addressed to it. So a relayed copy never reaches a program
twice, and the second packet to a machine goes straight to it rather than being
broadcast again.

`core.PORT` is 4021 and is now a virtual port. The physical one is Minitel's own
4096, and nothing here opens it.

Nothing sends a status report reliably. A report is replaced by the next one
within seconds, and the blocking form of a Minitel send sits inside a filtered
`event.pull`, which drops every keypress that arrives while it waits. That is
also why a program with a screen receives through `net.listen`, which registers a
handler that buffers what arrived and returns: a listener runs inside whatever
`event.pull` the program is already in, so nothing has to wait for the network.

A machine is named by `/etc/hostname`, which the daemon reads once when it
starts, so renaming one wants `rc minitel restart`. `ocwatch --edit` has a
network screen that writes the name, and `ocup` writes one on a machine that has
none yet.

A Minitel broadcast is delivered to every node on the same segment and
deliberately never forwarded, which is exactly as far as the old broadcast
reached. Crossing the mesh needs a name to send to, so `ocview` asks both ways:
one broadcast for whatever is in range, and one directed question per satellite
it has heard from before. That list fills itself in. A satellite that answers
once is written down, and from then on it is asked by name whether or not it is
still in range. `ocwatch --edit` shows the list, and adds a satellite that has
never been in range to be heard.

A satellite on that list that says nothing is named on screen. Two machines
answering to one name are named as well, which is otherwise indistinguishable
from a single machine that keeps going quiet.

### The log

An alert makes a sound and a colour, and when nobody was standing there, nothing
anywhere records that it happened. `syslog` is the channel that writes it down:
a service, a severity from RFC 5424, and a line of text, on port 514.

It is a record rather than a way of telling somebody in the room, which is why
it is asked separately from the other channels. An alert that switches the fuel
over is nobody's emergency, says nothing aloud, and is exactly what you want
written down when you come back and ask what happened.

Every machine keeps its own copy in `/home/ocgt.log`. Naming a collector in
`ocwatch --edit` under notifications sends them on as well: the machine whose
name that is receives, everybody else relays to it, and each one still keeps its
own copy, so a satellite that loses the network loses nothing. `syslogd` reads
its settings at start, so a change wants `rc syslogd reload`.

### One internet card for the base

`ocup` fetches over HTTPS when the machine has an internet card. When it has
none, it asks the network who does and fetches through them, using FRequest,
which is Minitel's file transfer protocol. `fserv` on the machine with the card
makes the request and hands back what came out.

Any machine running `ocwatch`, `ocserve` or `ocitems` that has an internet card
answers as the gateway, so nothing needs configuring for it. Naming one in the
network screen skips the asking.

The bootstrap is the exception. A machine with no internet card cannot fetch the
thing that would let it fetch, so it starts from a floppy: `ocmkfs` copies the
programs, the libraries, the daemons and the file that says to run them.

### The daemons

Three services, installed from `etc/` to `/etc/rc.d` and enabled by `ocup` in
`/etc/rc.cfg`. They start on the next boot, or with `rc <name> start`.

| service | what it does | where |
| --- | --- | --- |
| `minitel` | owns the modems, routes packets, raises the events | every machine |
| `syslogd` | writes records down, and relays them to the collector | every machine |
| `fserv` | serves files and proxies HTTP over the network | the machine with the internet card |

`ocping` says whether any of it works. `ocping <host>` sends a packet to a named
machine and times the acknowledgement, which tests routing, and prints what the
daemon has in its route cache. `ocping --l2` is the bare modem, which tests
whether two cards can hear each other at all. When the first fails, the second
says whether the fault is below Minitel or in it.

### What is vendored

Five files are not ours. They come from
[OC-Minitel](https://github.com/ShadowKatStudios/OC-Minitel) at commit
`c679ae36`, under the Mozilla Public License 2.0, and each says so at the top:
`lib/minitel.lua`, `lib/syslog.lua`, `etc/minitel.lua`, `etc/syslogd.lua` and
`etc/fserv.lua`. They are pinned rather than fetched, so `ocup` and `ocmkfs`
install them like anything else and a machine with no internet card can still
get them. Their version in `versions.txt` is the upstream commit, and they are
excluded from lint because they are not ours to fix.


The libraries install to `/lib`, each knowing about one thing:

| library | holds |
| --- | --- |
| `oclib` | component access, describing any value, colour codes, the painter, configuration |
| `ocgt` | GregTech: sensor text, gauges, machine names, machine status |
| `oclogistics` | Logistics Pipes: the `getPipe` proxy, router identity, and what the item and fluid networks hold |
| `ocrailcraft` | Railcraft: the boiler firebox, which is how hot a boiler is and whether it burns |
| `octank` | a fluid tank read through a transposer, by which side it sits on |
| `ocsecurity` | OpenSecurity: the alarm, which is its own loudspeaker |
| `ocnotify` | every way this base can say something happened, and which are wanted |
| `occomputronics` | Computronics: saying something aloud, and the colourful lamp |
| `ocnet` | the question one computer puts to another, and the answer |
| `minitel` | the network itself, vendored: addressing, meshing, streams |
| `syslog` | raising one record, vendored: a service, a severity, a line |

The mod-specific ones all build on `oclib` and know nothing of each other. A program asks each vocabulary it understands in turn, so support for
another mod is a new library and one more `or` rather than an edit to an
existing one.

`ocview` has three views, cycled with `v` and remembered between runs: `columns`
gives every satellite its own column of one-line machines, `cards` gives one
machine at a time with a wide bar, and `alerts` shows only what is wrong. A
machine set to compact in `ocwatch` draws as one line with no bar wherever it is
shown, and the order of the watch list is the order on screen, so a group of
pipes sits under the tank they belong to.

`ocwatch --edit` is one drawn screen listing what is watched and what will fire,
with the actions it offers as buttons along the bottom. Click a row to select
it, click it again to open it, or click a button; the arrow keys and the letter
each button names do the same. An alert opens onto its own screen: name,
thresholds, whether it counts as trouble, and the list of machines it acts on,
which you add to and remove from there. One trigger can stop any number of
machines, so two blast furnaces fed by one tank are one alert rather than two
kept in step by hand.

An alert watches either end of a range, and its own screen offers both. A tank
that must not run out trips below a floor and clears back above a ceiling. A
tank that must not fill up trips above a ceiling and clears back below a floor,
which is what turns a boiler house down: the steam tank reaching the top stops
the super tank feeding it creosote, the boilers run out of fuel, and the steam
falling back starts the fuel again. A super tank offers no auto-output switch of
its own to OpenComputers, so what stops it feeding anything is `setWorkAllowed`,
the same switch a blast furnace has. Both ends have two thresholds rather than
one, so a reading sitting on the boundary cannot fire on every refresh.

An alert that switches machines over as a matter of course is not trouble, and
saying so is one row on its own screen. An alert that counts as trouble is said
aloud, drawn red, and held on the lamp and the siren; one that does not acts on
its machines and says nothing. A base whose lamp is red all day has no red lamp
left to mean anything with, and a steam tank sits at its ceiling most of the
time.

When an alert trips, every notification channel that is switched on and has the
hardware for it carries the news. They are not alternatives to each other: a
lamp turning red, a siren, and a line in chat do different jobs, in different
rooms, at the same time. `ocwatch --edit` has a screen for them, where each one
switches on and off on its own, takes its own settings, and can be tested there
and then rather than the next time something goes wrong.

Two kinds of thing happen. An event is said once: a chat line, a spoken phrase,
a figure on a note block, a beep. A state is held until it is over: a lamp
colour, a siren. Every channel is asked on every change, because an alarm never
told the trouble ended goes on sounding. The lamp colours are chosen as plain
`rrggbb` and packed down to the five bits a channel the lamp really takes.

The speech box needs text-to-speech installed on the server. Without it, `say`
returns false while the call itself succeeds, so `core.setValue` hands back what
a method returned as well as whether it raised, and `ct.speak` falls through to
the chat box. What needs nothing installed is the alarm, the note block, the
chat box, and the computer's own beep. A Computronics speaker is not one of
them: it only carries audio from a tape drive or a speech box.

A Railcraft tank is why `octank` exists. It implements Forge's fluid handler and
nothing else, so OpenComputers has no driver for it: an adapter against it
exposes nothing and an MFU has nothing to bind to. A transposer, or an adapter
with a tank controller upgrade, reads any such tank by side. A watched entry
therefore carries a `side` as well as an address, since one transposer can have
a different tank on each of its six faces.

A Railcraft boiler is two blocks and only one of them has a driver. The firebox
answers how hot it is, how hot it can get and whether it is burning, which
`ocrailcraft` draws as a temperature gauge and a status: burning is working, and
a boiler that is hot and not burning is idle, since it goes on making steam out
of the heat it already has. How hot one can get is read once and kept, because
every call into a firebox blocks until the next server tick and the answer never
changes. The water and the steam are in the tank blocks above it, which have no
driver either and are read by side through a transposer like any other Railcraft
tank.

A GregTech tank reached through an MFU is a different matter: it answers
`setWorkAllowed`, and its pump covers set to the working state of the device turn
with it, so one alert stops four boilers at once. It answers no
`getSensorInformation` through the MFU, so what is in it has to be read some
other way.

`ocitems` lists the item network, the most plentiful first, with a panel beside
it naming the items whose stock is moving: what has been added over the last
three minutes at the top, what has been taken at the bottom, and nothing that is
standing still. Three minutes rather than one because a stock that moves in
bursts sits still through a short window and never reaches the screen.

Asking a request pipe what it has costs about 950 KB in a single go, so it is
asked only when the memory for it is there.

After that it refreshes whichever way the machine can afford, which it decides
for itself. Reading the names out of a read is nearly all of what one costs —
1,592 counts arrive in a twentieth of a second, the names behind them take three
— and the network answers in the same order every time, so most reads are taken
as counts alone and matched to the names the last full read established. That is
checked rather than assumed: the total has to match and eight positions are
named and compared, and a read that fails either is read properly instead.

What it tracks is the few hundred stocks there is most of, and that is a choice
rather than a limit. Every name is memory a read cannot use, and the read is
what makes the counts move: a server naming 1,286 items keeps 1.3 MB and can
never read again, where one naming 486 keeps 2.2 MB and reads in a twentieth of
a second. The tail is things there are three of, and it is not worth paying for
in refresh rate.

The network answers with one entry per identifier, so
a worn pair of golden boots is a dozen entries and an enchanted book is dozens
more; anything damageable or carrying an NBT tag is dropped, because it is one
thing somebody is carrying rather than a stock, and it crowds out the ones that
are. A meta variant that is a real item, wool by colour or a dust by grade, is
neither and stays. How many are named is settled by asking the machine as it
goes rather than by a sum: a computer with 1.4 MB holds a few hundred, a server
with 3.8 MB holds the lot.

A read is about 950 KB whichever way it is taken, so how often one really
happens is settled by free memory rather than by a clock. Counting an item at a
time costs a server tick each — a minute to go round a list of a thousand — and
is what a machine without the memory for a read is left with. It is not idle
work in between either: memory comes back only under the pressure of asking for
more, so the counting is what makes the next read affordable.

A read brings new tables, and the window a rate is measured over lives on the
old ones, so a read is folded into what is already known rather than replacing
it. What is known keeps its window, what is new starts one, and what the network
no longer has is dropped.

Two numbers an item are written to `/etc/ocitems.cache` with the name and the
last count, which is what lets a second run start with a full screen. A machine
with a network card also answers for what it is watching, so `ocview` shows the
item network beside the machines without a second program to run.

The fluid network is a second pipe answering a different question, and this
version of Logistics Pipes is the first to answer it: a fluid request pipe has
`getAvailableFluids`, where an item request pipe has `getAvailableItems` and
neither has both. So a base can have one network and not the other, and each is
looked for on its own.

Nothing the item side spends its life managing applies to the fluids.
`getAvailableFluids` answers with a plain table of registry name to
millibuckets, so the names arrive with the amounts, one call is the whole
answer, and there is no cheaper way to take it and nothing to count an item at a
time. A base stocks thousands of items and tens of fluids, so the read is small
enough to make on a clock and the whole list is worth a place on the screen
rather than only the part of it that is moving.

What the network calls a fluid is not what anybody else calls it. The registry
name is `nitrofuel`, and the fluid is Cetane-Boosted Diesel, so each one is
asked for the name it is shown under. That costs nothing: only
`getAvailableFluids`, `getFluidAmount` and `makeRequest` wait for a server tick,
and building an identifier to read a name off does not.

`ocview` shows the fluids the same way, sent along with the machines by whatever
is watching them. What is moving is shown beside each fluid rather than in the
panel of items that are changing: an item count and a figure in millibuckets are
different sizes of number, and a list sorted across both of them says nothing.

A computer with a request pipe and nobody looking at its screen is what
`ocserve` is for, and it is the right home for this: it counts the item network
between the questions it answers, and sends the few items that are moving along
with its machines, so `ocview` shows what the base is gaining and losing beside
what its machines are doing. A rack server has the memory for far more of the
network than a computer does, which is what makes it the place to run it.

`r` reads the whole network again. That is the only way an item nobody has ever
had appears, and the only way a tool or anything else carrying an NBT tag is
counted, since two numbers do not say which variant of it is meant. It is
refused when the memory for it is not there, because asking anyway does not fail
the call, it ends the computer.

Each program carries a `VERSION` constant. `ocup` compares the installed copy
against the downloaded one and reports `v0.2.0 -> v0.3.0` when it changes, so
you can tell whether an update actually landed.

`manifest.txt` lists one path a line and nothing else, which is all an older
`ocup` can read. `versions.txt` lists the same paths with more beside them. The
folder decides where a file lands: `programs/` installs to `/bin`, `lib/`
installs to `/lib`, `etc/` installs to `/etc/rc.d`.

Installing a daemon does not run it, so `ocup` also adds it to the `enabled`
list in `/etc/rc.cfg`, leaving anything already there alone, and writes settings
for it if there are none: both vendored daemons ship with a default that is no
use here, one writing its records to `/dev/null` and the other refusing to proxy
at all.

A line in `versions.txt` is a path, the version that file declares, and its size
in bytes. `ocup` compares both against the copy already installed and downloads
only what differs, so a run with nothing to do costs two requests, the commit
and the manifest, rather than one per file.

The size is there because a version alone is only as good as the discipline
behind it: a library once got rewritten and kept its number, so every computer
went on running the old one and crashed on a function that was no longer there.
Bytes change whatever anybody remembered to do.

Regenerate both files with `nix develop -c lua machine/manifest.lua`. Checks fail
if they are out of step with the sources, if the two lists drift apart, or if a
`manifest.txt` line ever gains a second word, which is what an older `ocup`
cannot read.

Not every computer wants every program. `ocup install` lists what the manifest
offers, records the choice in `/etc/ocgt.cfg` as `programs`, and then installs
it. Move with the arrow keys, toggle with space, enter installs what is ticked,
q leaves everything as it was. A computer that has never
chosen gets `ocup`, `ocdebug` and `ocdump`: enough to look at the machines in
front of it and to ask for help with them. Once a choice exists it is the whole
truth:
`ocup` installs what is in the list and takes anything else off `/bin`, so what
is installed is always what was chosen. `ocup` itself cannot be opted out,
since nothing would be left to opt back in with. Libraries are not part of the
choice, because the programs that stay need whichever of them they require.

## Install

On a fresh computer, fetch `ocup` once and let it install the rest:

```
wget https://raw.githubusercontent.com/lucemans/oc-gtnh/refs/heads/master/programs/ocup.lua /bin/ocup.lua
ocup
```

`ocup` updates itself first and reloads into the new copy, so the rest of the
run already uses the behaviour that was just downloaded.
`raw.githubusercontent.com` caches for five minutes, so a push is not visible
to `ocup` immediately.

That first run installs the daemons and enables them, but does not start them.
Reboot, or start them by hand:

```
rc minitel start
rc syslogd start
rc fserv start        only on the machine with the internet card
```

A machine with no internet card has nothing to fetch `ocup` with in the first
place. Flash a floppy on a machine that has one, with `ocmkfs`, then `install`
from it there.

## Development

`machine/` is a fake OpenComputers machine: components, a screen buffer, an
event queue, a virtual filesystem and a scriptable internet card. It is enough
to run the programs outside Minecraft and assert on what they draw, write and
send.

```
nix develop -c lua machine/test.lua          # run every check
nix develop -c lua machine/test.lua --show   # also print screens and payloads
nix develop -c luacheck programs/ machine/   # lint
```

Run these from the repository root; the checks load `programs/*.lua` by
relative path. The dev shell pins Lua 5.3, the version OpenOS 1.8.9 runs.
