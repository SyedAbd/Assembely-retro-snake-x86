# Snake (8088 / DOS, NASM)

A single-file recreation of a classic Snake game in x86 assembly, targeting
the original IBM PC / 8088 running DOS. Built and tested against NASM and
DOSBox.

## Features

- 80x25 text mode, colored-background snake with a direction-arrow head
  (`>` `<` `^` `v`) and a lettered food pickup
- Wraps around all four edges: going off one side brings you back on the
  same row/column on the opposite side
- Eating food grows the snake and increases the score
- Running into your own body ends the game
- Game speed ramps up gradually the longer you survive
- No BIOS keyboard (`INT 16h`) or clock (`INT 1Ah`) calls during play.
  Input comes from hooking `IRQ1` (`INT 09h`) and reading raw scan codes
  off port `60h` directly; timing runs off a tick counter driven by
  hooking `IRQ0` (`INT 08h`), chained to the original handler so the
  system clock keeps working while the game runs. Both interrupt vectors
  are restored before exit.

## Build

Requires [NASM](https://www.nasm.us/).

```
nasm -f bin -o snake.com snake.asm
```

## Run

Requires a DOS environment. [DOSBox](https://www.dosbox.com/) is the
easiest way to run it on a modern machine:

```
dosbox snake.com
```

It also runs on real or emulated 8088/8086 hardware under plain DOS.

## Controls

| Key          | Action           |
|--------------|------------------|
| Arrow keys   | Steer            |
| Esc          | Quit             |
| Any key      | Continue past the game-over screen |

You can't reverse directly into yourself (pressing the opposite direction
while moving is ignored).

## Notes

This is a single `.com` file, no external assets or libraries. The whole
thing fits in a few KB, in keeping with what would actually run on the
hardware it's emulating.
