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
| `ocdump`    | uploads a full system dump as an unlisted paste, `--net` for the mesh  |
| `occonnect` | lets someone off the machine run commands on it, through the proxy     |
| `ockeypad`  | a PIN lock on an OpenSecurity keypad                                   |
| `ocmkfs`    | flashes a floppy with the programs you pick, for a computer with no net |
| `ocinstall` | on the new machine: keeps what it wants of the floppy, records the choice |
| `ocsweeper` | minesweeper, up to 21x21                                               |
| `octiles`   | 2048, from 2x2 up to 8x8                                               |
| `ocitems`   | everything the Logistics Pipes network holds, items and fluids alike   |
| `ocagent`   | the base's agent: `@c` in chat reaches a model that can ask the mesh and run Lua |

## Driving a computer from outside the game

Two programs let something outside the game hold a computer here: `occonnect`
hands over its shell, and `ocagent` hands over chat, the mesh and its shell to
a language model. Both go through one proxy, and both are linked the same way:

```
ocharness keys vps:7071                       here, once: mints both secrets
ocagent --link vps:7071 <secret> <key>        on the machine, one line
ocagent --link                                what it is linked to, secrets masked
```

`ocharness keys` prints the two lines to type. The secrets are twelve
characters from an alphabet nothing is mistaken for, because they are typed on
an OpenComputers keyboard; the proxy stops challenging an address after five
failed joins in ten minutes, so a short secret is not a guessable one. The
network screen of `ocwatch --edit` shows the same `link` row for editing by
hand.

```
 shell / agent harness                         proxy                    the computer
 (your machine)         ---- TCP, sealed ---->  (a VPS)  <---- TCP, sealed ----  (in the game)
                              controller                        device
```

The proxy is on the public internet. It authenticates every connection with a
secret of its own, knows a device by the hostname it joined under, lets one
controller attach to it, and forwards frames between the two without reading
them. It holds the proxy secret and nothing else: what the frames carry is
sealed with the link key, which only the computer and its controller have.
Changing the harness never touches the proxy, and changing the proxy never
touches the computers, which is the point of having two.

The computer needs an internet card and a tier 2 data card. The data card does
the sealing, and a tier 1 has only the hashes.

### The link

One TCP stream from the internet card, carrying frames both ways:

```
u16 length, u8 channel, body
```

Channel 0 is the proxy's own. On connect the proxy sends a 16 byte challenge in
the clear; the client answers with a join sealed under keys from the proxy
secret, naming itself, its role, the challenge and a nonce of its own, and both
sides then run the channel under keys derived from challenge and nonce
together. A recorded join answers a challenge that will never be asked again.
After that the proxy says `joined`, and `attached` or `detached` as the other
end comes and goes. A quiet client says `ping` once a minute, and the proxy
drops one that says nothing for three.

Channel 1 is relayed as it is between a device and its controller. A sealed
body, on either channel, is

```
iv .. aes_128_cbc(key, iv, text) .. hmac_sha256(mac, iv .. ct)[1..16]
```

with the data card doing the arithmetic. The device says hello under the
static link keys when the proxy attaches it, carrying a fresh nonce, and
everything after runs under keys derived from that nonce, so a frame recorded
yesterday verifies against nothing today. Every message numbers itself, on both
channels, and a number that does not go up is dropped.

Inside a frame the text is OpenOS serialization both ways. The computer reads
and writes it out of the standard library, and the other side carries a serde
dialect for it in `remote/link/src/wire.rs`, so nothing is parsed by hand and
there is no JSON library on a machine that cannot afford one.

The card's AES, its HMAC and its padding were checked against this crate on a
real card, and the values are pinned in `remote/link/src/frame.rs`.

| from the device | meaning |
| --- | --- |
| `hello` | protocol, hostname, nonce; under the static link keys |
| `chat` | a player and what they typed after the trigger, `ocagent` only |
| `partial` | one machine's answer to a mesh question, as the mesh sent it |
| `result` | a command done, with its output, or a question closed with a count |
| `heartbeat` | free memory and uptime every thirty seconds, `ocagent` only |

| from the controller | meaning |
| --- | --- |
| `welcome` | the hello was accepted; the link is open |
| `shell` | a shell line to run, output read back from a file |
| `run` | a chunk of Lua to run, with `print` collected, 4 KB at most |
| `file` | a file to write |
| `say` | one line for the chat box, `ocagent` only |
| `ask` | `status`, `log` or `versions` for the mesh, `ocagent` only |

## occonnect

```
occonnect          connect and wait for commands
occonnect --once   one round, for checking it works
```

The machine joins the proxy under its hostname and waits. Its controller is
`ocharness` on your machine:

```
ocharness shell <host> ocup                       run a shell line, print what it wrote
ocharness lua <host> probe.lua                    run a chunk, print what it printed
ocharness file <host> /home/notes.txt notes.txt   write a file
```

Nothing is restricted: whoever holds the link key drives the shell. A machine
that is not connected is said to be so within ten seconds rather than waited
for. The old ntfy path is gone: a public relay that anybody could post to was
authenticated by a code inside each message, and this one is authenticated
before a byte of content moves.

## ocagent

A line in chat that starts with `@c` or `@computer` goes to a language model,
and what it says comes back through the chat box. The model can ask the mesh
what every satellite sees, add up the fluids, read the log, say what every
computer is running, and run a chunk of Lua on the agent computer.

```
@c how much diesel do we have
@c what tripped last night
@c list every tank under ten percent
```

The model does not run in the game. A computer with under a megabyte cannot
hold a conversation, a tool schema and a parsed response, so it holds none of
them. `ocagent` is a bridge: it carries chat lines out and carries back three
kinds of command, say this, ask the mesh that, run this Lua. It answers
everything `occonnect` answers as well, so the same link drives its shell.

```
ocagent          connect to the proxy and serve
ocagent --once   one round, for checking it works
```

The agent computer needs a Computronics chat box on an adapter as well. The
chat box raises a `chat_message` signal for every line typed within its range,
forty blocks unless changed, and is what the reply is said through. Nothing
else on the base changes: the bridge asks the satellites the questions
`ocview` already asks.

### Staying up

The bridge is a program with its own loop, started from `/home/.shrc` like
`ocserve`, and never an `rc` daemon: a loop that runs scripts and pumps a
socket does not return promptly. Listeners only queue what arrived; every
reply, question and script runs from the loop. A script runs under `pcall`
with its output bounded at 4 KB, and the game's own watchdog stops one that
never yields, as an error the bridge survives. Before a script runs the bridge
asks for its memory back the way `ocitems` does, and refuses when there is not
enough. Three loop errors in a minute, or memory that stays gone after a
collection, reboot the machine, and the reboot lands back in `ocagent`.

When the proxy is away, chat is told so, once every thirty seconds at most,
and the bridge reconnects with a pause that doubles up to a minute. A connect,
a challenge or a join that never completes is dropped after ten seconds, since
the card itself never gives up. When the harness is away the proxy says
`detached`, the bridge goes back to waiting, and greets the next controller
with a fresh hello.

### The proxy and the harness

Both live in `remote/`, a Cargo workspace: `link` is the wire they share,
`proxy` builds `ocproxy`, `harness` builds `ocharness`. Both binaries start at
0.0.1 and are versioned separately, since the proxy changes only when the
wire does.

```
cd remote
cargo build --release
./target/release/ocharness keys vps:7071                       mints the secrets
PROXY_SECRET=... ./target/release/ocproxy                       on the VPS
PROXY_ADDR=vps:7071 PROXY_SECRET=... LINK_KEY=... DEVICE=agent-01 \
  LLM_BASE_URL=https://your-litellm/v1 LLM_API_KEY=... LLM_MODEL=... \
  ./target/release/ocharness serve                              on your machine
```

| variable | who reads it | what it is |
| --- | --- | --- |
| `PROXY_LISTEN` | proxy | address to listen on, `0.0.0.0:7071` when unset |
| `PROXY_SECRET` | both | the proxy secret, as the network screen was given it |
| `PROXY_ADDR` | harness | host and port of the proxy |
| `LINK_KEY` | harness | the link key, as the network screen was given it |
| `DEVICE` | harness | hostname of the agent computer, for `serve` |
| `LLM_BASE_URL` | harness | an OpenAI-compatible base, up to and including `/v1` |
| `LLM_API_KEY` | harness | sent as a bearer token when set |
| `LLM_MODEL` | harness | the model name the proxy knows |
| `AGENT_PROMPT_FILE` | harness | a file appended to the system prompt, for what the base is like |
| `RUST_LOG` | both | `info` when unset |

The model gets six tools: `base_status`, `fluid_totals`, `base_log`,
`base_versions`, `run_lua` and `confirm`. The first four are the questions the
mesh already answers, compacted into a few lines each. `run_lua` runs on the
agent computer with any method available, and the system prompt tells the
model to call `confirm` before anything that changes the world. `confirm`
says the question in chat and waits a minute for the same player to answer
`@c yes`; anything else is a refusal.

One turn may take eight tool rounds and ninety seconds, and a turn past four
seconds says so in chat. A player gets five questions a minute, a line while a
turn runs is queued, and the last twenty exchanges ride along into the next
turn. An answer is split into lines of two hundred characters, six at most.

A second controller for a device is refused by the proxy, so `ocharness shell`
onto the agent computer while `ocharness serve` holds it is answered with
`busy`. Stop the harness first, or drive it through chat.

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

### Names

A machine is named by `/etc/hostname`, which the daemon reads once when it
starts, so renaming one wants `rc minitel restart`. `ocwatch --edit` has a
network screen that writes the name, and `ocup` writes one on a machine that has
none yet.

There are three places a name can be, and only one of them is the truth:

| where | who reads it | when it is written |
| --- | --- | --- |
| `/etc/hostname` | the Minitel daemon, at start | `ocup`, and the network screen |
| `HOSTNAME` in the shell | OpenOS, and anything asking it | `hostname --update`, per shell |
| `hostname` in `/etc/ocgt.cfg` | nothing, now | the network screen, as a record of what was asked for |

The file is the truth, because the daemon names every packet out of it and
nothing else gets a say. `HOSTNAME` is a copy taken whenever `hostname --update`
last ran, so it can name something the daemon has never heard of, and believing
it over the file is how a machine addresses its own loopback to a name that is
not its own. Both places are written together whenever the name changes, so they
do not drift, but the file is what gets asked.

A name has to be something a packet can carry: letters, digits, dot, dash and
underscore, starting with a letter or digit, up to 63 characters. The network
screen refuses anything else rather than writing a name that cannot be routed
to. A leading `~` is refused in particular, because that is how Minitel marks a
broadcast.

Minitel ships an `mtcfg` for all of this, in a package called `minitel-util`.
Nothing here needs it. It sets the hostname, enables the service and starts it,
and writes `/etc/minitel.cfg`, and `ocup` does the first three itself while the
daemon writes the fourth with the defaults this base wants anyway. Running it is
harmless; skipping it costs nothing.

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

`ocview`'s `log` view is how you read them. Each record shows as how long ago,
which machine raised it, what raised it, and what it said, in red for an error
and grey for the routine.

Who it asks depends on whether a collector is named. With one, it asks only the
collector, which already holds a copy of everybody's records; asking the
satellites as well would show every record twice. With none, every machine keeps
its own and nobody holds the lot, so it asks all of them and what comes back is
one base's history between them.

That merge works because a record travels as an age rather than a stamp. There
is no wall clock here and two machines' uptimes have nothing to do with each
other, so a raw stamp cannot be compared across machines. An age can, which is
why the answer carries the answering machine's own clock beside the records and
the ages are worked out against that before anything is sorted.

A machine that has never written anything answers with nothing in it rather than
staying silent, because silence and an empty history look the same on the
screen and only one of them is worth walking over to the machine about.

Only the last 4 KB of the file is ever read. It grows all week and is never
rewritten, so reading it whole to show a screenful is how a small computer runs
out of memory looking at its own history. Only the view that shows them fetches
them, for the same reason: it is a screenful that barely changes, where the
machines change every two seconds.

### Updating the base from one screen

`ocview`'s fifth view is `update`. It lists every machine, what it is running,
the commit `ocup` last installed from, how long it has been up, and how far
through an update it is.

| key | what it does |
| --- | --- |
| up and down | move between machines |
| `u` | update the machine on the cursor |
| `a` | update every machine |

A machine told to update answers to say it heard, runs `ocup` on a cleared
screen, and reboots. The reboot is the point: overwriting a file changes nothing
that is already running, a library already required stays required, and a daemon
reads its own file once when `rc` starts it. Coming up again is the only thing
that puts a machine on what it just fetched.

Coming up again needs something to come up into. `ocup install` has a row saying
what starts at boot, and `ocup` writes that to `/home/.shrc`, which is what
OpenOS runs for an interactive shell. Without it a machine reboots to a prompt
and is never heard from again. `rc` is not the answer here: a service has to
return promptly so it can register its listeners, and a dashboard that owns the
screen and reads the keyboard never returns at all.

`a` goes one machine at a time and leaves the gateway until last. Twelve
satellites fetching at once go through one internet card, a gateway that rebooted
first takes away everybody else's way of getting anything, and a base with every
computer rebooting together is watching nothing at all for as long as it takes.
A machine that has not answered three minutes after being told is given up on,
said so on the screen, and the queue moves on.

What each machine is running is asked for only while this view is open, and is
answered out of the configuration, where `ocup` wrote it. Neither end goes to a
disk for any of it, which matters: a disk in this game is audible across the
room, and a dozen satellites answering the same question on a clock is a dozen
disks going round.

There is nothing checked against the repository here. A tablet has no idea what
GitHub holds and does not need one: what the view compares is the base against
itself, so a machine behind the one beside it is named along with the files it is
behind on. A base where every machine agrees is a base that is fine, whatever
the repository has moved on to since.

Anybody who can put a packet on the mesh can trigger this. Everything on the
status port is already like that.

### Metrics, for Grafana

Readings also go to a telemetry service, as GTP/1, which is a specification of
this base rather than one of Minitel's own. It uses virtual port 2000.
A message is `GTP1:` and then a serialized table, sent unreliably, one message
to a packet.

The whole coupling to that service is the shape of those bytes. It owns
everything past them: the `gtnh.` prefix, the Graphite translation, validation,
and the `host`, `site` and `area` labels, which it works out from the sender
rather than being told.

A reading here is a label and a number, and a metric there is a name and a
number with labels saying what it was measured on. So `ocgtp` is mostly a
translation, and the part of it that matters is refusing to guess:

| what arrives | what is sent |
| --- | --- |
| a gauge in `L` | `fluid.amount_liters`, `fluid.capacity_liters`, `fluid.fill_ratio`, labelled `fluid` and `machine` |
| a gauge in `EU` | `energy.stored_eu`, `energy.capacity_eu`, `energy.fill_ratio`, labelled `machine` |
| a firebox in `C` | `machine.temperature_kelvin`, converted rather than renamed |
| a machine's status | `machine.active`, 1 when it is working |
| an alert | `alert.tripped`, 1 or 0, labelled `alert` |
| the fluid network | `fluid.amount_liters`, labelled `fluid` |
| the program running | `software.build_info`, always 1, labelled `program`, `version` and `commit` |
| a unit nothing here recognises | nothing at all |

That last row is the rule the rest follows from. A series invented out of a unit
nobody recognised sits in the database being wrong for as long as the database
exists, and no dashboard is worth that.

`software.build_info` is the one whose value says nothing. A version is not a
number and cannot be made into one, so the series carries a constant and the
version rides in a label, which is how a build stamp reaches a metrics database
anywhere. One line per machine on a dashboard then says which of them is behind
the rest. The commit is the short one, and it comes from what `ocup` wrote down
on its last run.

Nothing about the item network is sent. A base holds thousands of item names and
each one as a label value is a series of its own, which is the one mistake the
specification names twice.

The samples come out of the report `ocnet` already built for the dashboard,
rather than from the machines again. That is what stops the screen and the graph
disagreeing about a scale, and it means telemetry costs no machine reads beyond
the ones already happening.

`site` and `area` come from the first two parts of the hostname, so the names
are worth choosing:

| machine | hostname | gives |
| --- | --- | --- |
| the one running `ocview` | `ovw-core-view-01` | `site=ovw area=core` |
| the boiler room | `ovw-pwr-steam-col-01` | `site=ovw area=pwr` |
| the blast furnace | `ovw-smelt-ebf-col-01` | `site=ovw area=smelt` |
| the chemical room | `ovw-chem-oil-col-01` | `site=ovw area=chem` |

The service to send to is `ovw-core-obs-01` every ten seconds until told
otherwise, which is the deployment the specification names. `ocwatch --edit` has
it on the network screen, and blank turns it off. Off is a real answer: a
machine sending to a service that is not there puts one unroutable packet across
the mesh every interval, forever.

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

`rc` starts them at boot: `/boot/89_rc.lua` listens for the `init` signal, which
is raised before the shell, so a service in `enabled` is up before anything on
`/home/.shrc` runs.

When that has not happened, the program starts the daemon rather than telling
somebody to. `net.up` sends this machine a packet addressed to itself, which the
daemon hands straight back and nothing else does; if nothing comes back it runs
`rc minitel enable` and `rc minitel start` and asks again. Enabling as well as
starting is the point: starting fixes this boot, enabling is what stops the next
one going the same way. It says on screen that it had to.

If it still does not answer, the daemon is either failing to start or running
under a name this machine does not call itself. It hands a packet back only when
the address matches what it read out of `/etc/hostname` when `rc` started it, so
a name changed since then looks exactly like a daemon that is not there.
`rc minitel restart` is what makes it read the file again.

`ocping` says whether any of it works. `ocping <host>` sends a packet to a named
machine and times the acknowledgement, which tests routing, and prints what the
daemon has in its route cache. `ocping --l2` is the bare modem, which tests
whether two cards can hear each other at all. When the first fails, the second
says whether the fault is below Minitel or in it.

`ocdump --net` writes the same picture into a dump somebody else can read. It
adds this machine's hostname, whether the daemon answers its own loopback, every
network card with its strength, the route cache, the satellites written down,
and then what each satellite reports: its machines, their gauges, the alerts,
the fluids and whatever items are moving. It asks everyone at once and waits
five seconds, so a satellite that says nothing is in the dump as `no answer`.
That is the line worth reading, because a satellite missing from a dashboard and
a satellite that is switched off look the same on the screen.

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
| `ocgtp` | readings as metrics, for whatever is collecting them |
| `minitel` | the network itself, vendored: addressing, meshing, streams |
| `syslog` | raising one record, vendored: a service, a severity, a line |

The mod-specific ones all build on `oclib` and know nothing of each other. A program asks each vocabulary it understands in turn, so support for
another mod is a new library and one more `or` rather than an edit to an
existing one.

`ocview` has five views, cycled with `v` and remembered between runs: `columns`
gives every satellite its own column of one-line machines, `cards` gives one
machine at a time with a wide bar, `alerts` shows only what is wrong, `log`
shows what the base has written down, and `update` shows what every machine is
running and moves it on. A
machine set to compact in `ocwatch` draws as one line with no bar wherever it is
shown, and the order of the watch list is the order on screen, so a group of
pipes sits under the tank they belong to.

The first three are what the base is doing now. `log` is what it did while
nobody was watching, which is the only view that answers "what happened at four
this morning". `update` is not about the base at all but about the computers
watching it, and is the only view that changes anything.

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
chosen gets `ocup`, `ocdebug`, `ocdump` and `ocinstall`: enough to look at the
machines in front of it, to ask for help with them, and to set up the next
machine from a floppy. Once a choice exists it is the whole truth:
`ocup` installs what is in the list and takes anything else off `/bin`, so what
is installed is always what was chosen. `ocup` itself cannot be opted out,
since nothing would be left to opt back in with. Libraries are not part of the
choice, because the programs that stay need whichever of them they require.
The same list has a row at the bottom saying what starts at boot, cycled through
the programs this machine is keeping. `ocup` writes that to `/home/.shrc`, which
is the only autostart OpenOS has, and offering a program the machine is not
installing would name a file that is about to be deleted.

Every run also records what it put where, as `installed` in `/etc/ocgt.cfg`: the
commit it fetched from and the version of each file. That is what a machine
answers with when a dashboard asks what it is running, so nothing has to open a
file to say. `ocmkfs` writes the same thing onto a floppy, so a machine installed
off one can answer before it has ever reached the internet.

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

That first run installs the daemons, enables them in `/etc/rc.cfg` and starts
them, so there is no state where the network is installed and not running. It
also names the machine if it has no name yet, after the first eight characters
of its address, which `ocwatch --edit` then changes to something worth reading.

A machine with no internet card has nothing to fetch `ocup` with in the first
place. Flash a floppy on a machine that has one, with `ocmkfs`, then on the new
machine run `install` and then `ocinstall`.

```
install      copies the floppy onto the machine, which is usable at that point
ocinstall    drops the programs this machine does not want
```

The floppy carries every program, because it is made before anybody knows which
machine it is for, and it carries the list of them as `programs` in
`/etc/ocgt.cfg`. That list is what stops the next `ocup` run from removing the
lot: `ocup` treats a recorded choice as the whole truth, so a floppy that copied
programs and said nothing about them left a machine that threw them away on its
first update.

`ocinstall` is where one machine narrows that list. It shows what is in `/bin`,
removes what is turned off, and writes the rest back. Everything else in the
configuration is read and put back untouched, so the machines being watched, the
alerts, the satellites and the telemetry service survive it. It needs no network,
which is the point: the machine it runs on usually has none yet.

`ocping` is what to run when something is wrong. It says whether the daemon is
running, what this machine is called, and what it knows about where the others
are.

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
