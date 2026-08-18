# Notes on the GregTech component API

Everything here was read off real dumps, not documentation. Sources:
[dump 1](https://dpaste.com/DQ76EXBK4.txt), [dump 2](https://dpaste.com/32FW2BMJ6.txt).
Both pastes expire; re-dump rather than trust these if something looks wrong.

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

Two conventions hold across every machine seen so far:

- **The first line is the display name.** `"§9Super Tank§r"`,
  `"§9Medium Voltage Battery Buffer§r"`. Far better than `getName`, which
  returns internal ids like `super.tank.tier.01` or
  `basicgenerator.diesel.tier.02`.
- **Current value is `§a`, maximum is `§e`.** True for a tank's fluid and a
  buffer's charge alike, so one rule builds a gauge for any machine that
  reports one. Numbers are comma-grouped and followed by a unit.

Observed shapes:

```
tank:    {"§9Super Tank§r", "Stored Fluid:", "§6Bio Diesel§r",
          "§a42,000 L§r §e4,000,000 L§r"}
buffer:  {"§9Medium Voltage Battery Buffer§r",
          "Stored Items: §a832,768§r EU / §e832,768§r EU",
          "Average input: 0 EU/t", "Average output: 0 EU/t"}
```

The text before the first number labels the reading (`Stored Items:`), or is
empty when the line opens with the number, as a tank's does.

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

| component          | notes                                                     |
| ------------------ | --------------------------------------------------------- |
| `gt_machine`       | covers generators *and* super tanks; distinguish by sensor |
| `gt_batterybuffer` | adds `getBatteryCharge(slot)`, `getMaxBatteryCharge`       |

A super tank reports `getSteamStored`, `getEUStored` and friends as zero. Do
not build a summary from those; prefer the sensor lines and fall back to the
numeric getters only when a machine has no sensor output.
