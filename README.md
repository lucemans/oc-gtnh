# Open Computers Programs in GTNH

Lua programs for the OpenComputers mod in GregTech New Horizons.

https://ocdoc.cil.li/api:internet

## Programs

| program     | what it does                                                          |
| ----------- | --------------------------------------------------------------------- |
| `ocup`      | fetches `manifest.txt`, then installs the programs this computer chose |
| `ocwatch`   | fixed dashboard for chosen machines, with thresholds that can act      |
| `ocdebug`   | live on-screen browser for components, their methods and values        |
| `ocdump`    | uploads a full system dump as an unlisted paste, to share for support  |
| `occonnect` | lets someone off the machine run commands on it, over HTTPS            |
| `ockeypad`  | a PIN lock on an OpenSecurity keypad                                   |
| `ocmkfs`    | flashes a floppy with the programs you pick, for a computer with no net |
| `ocsweeper` | minesweeper, up to 21x21                                               |
| `ocitems`   | everything a Logistics Pipe will tell you about itself                 |

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

The libraries install to `/lib`, each knowing about one thing:

| library | holds |
| --- | --- |
| `oclib` | component access, describing any value, colour codes, the painter, configuration |
| `ocgt` | GregTech: sensor text, gauges, machine names, machine status |
| `oclogistics` | Logistics Pipes: the `getPipe` proxy and router identity |
| `octank` | a fluid tank read through a transposer, by which side it sits on |
| `ocsecurity` | OpenSecurity: the alarm, which is its own loudspeaker |
| `ocnotify` | every way this base can say something happened, and which are wanted |
| `occomputronics` | Computronics: saying something aloud, and the colourful lamp |
| `ocnet` | the question one computer puts to another, and the answer |

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
thresholds, whether it announces itself, and the list of machines it acts on,
which you add to and remove from there. One trigger can stop any number of
machines, so two blast furnaces fed by one tank are one alert rather than two
kept in step by hand.

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

Each program carries a `VERSION` constant. `ocup` compares the installed copy
against the downloaded one and reports `v0.2.0 -> v0.3.0` when it changes, so
you can tell whether an update actually landed.

`manifest.txt` lists one path a line, followed by the version that file
declares. The folder decides where a file lands: `programs/` installs to `/bin`,
`lib/` installs to `/lib`.

The version is what makes an update quick. `ocup` compares it against the copy
already installed and downloads only the files that differ, so a run with
nothing to do costs two requests, the commit and the manifest, rather than one
per file. That means a file changed without its `VERSION` moving will not be
picked up; delete it and run `ocup` again if that happens. Regenerate the
manifest with `nix develop -c lua machine/manifest.lua`, and a check fails if it
is ever out of step with the files.

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
