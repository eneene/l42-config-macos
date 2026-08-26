# L42 Config — Printer Utility for macOS

> **🇧🇷 Utilitário de configuração para a impressora térmica Elgin L42PRO /
> L42PRO FULL no macOS.** A Elgin só distribui o "L42 Pro Utility" para
> Windows — este é o equivalente para Mac. Lê e grava as configurações da
> impressora (escurecimento, velocidade, tipo de etiqueta, offsets,
> calibração, ação ao ligar), mostra firmware, número de série e contadores,
> ajusta também os padrões do driver no macOS, e traz um console para enviar
> comandos ZPL direto. Instalação: baixe o `.dmg` na
> [página de releases](../../releases/latest) e arraste o aplicativo — sem
> instalador. Conexão Ethernet dá acesso completo; por USB o app apenas envia
> comandos (limitação do macOS, explicada abaixo).

A macOS counterpart to Elgin's Windows-only **L42 Pro Utility**. It talks to
the printer over TCP 9100, reads the live configuration with `^HH`, and writes
settings back with ZPL. Field names follow the Elgin utility so the two can be
used side by side.

## Features

- **Read and write printer settings** — print method, print mode, media type,
  label size, tear-off position, max calibration length, power-up and
  head-close actions, column/row offsets, darkness, speed
- **More than the Comum tab** — reprint after error (`^JZ`), mirror (`^PM`),
  180° invert (`^PO`), symbol set (`^CI`), RS-232 parameters (`^SC`)
- **Printer information** — firmware, serial number, resettable and absolute
  counters, RAM and flash free, head usage, IP / mask / MAC
- **Driver defaults tab** — edits the *macOS queue's* defaults (what the print
  dialog opens with), which are separate from the printer's own memory
- **Functions** — calibrate sensor, print configuration label, feed, save to
  printer memory, restart, recall saved, zero counter, hex dump mode, factory
  reset
- **Command console** — send raw ZPL or `<STX>K…` and see the reply
- **Save and load** configurations as JSON

Every command is taken from the PPLZ programmer's manual rather than guessed.

## Compatibility

| Printer / connection | Status |
|---|---|
| L42PRO FULL, Ethernet | tested — read and write |
| L42PRO (base model), USB | send only — see below |
| Other ZPL/PPLZ printers | likely works; the command set is standard |

**USB is send-only, and that is a macOS limitation, not a printer one.** A USB
printer on macOS is owned by CUPS, which is a one-way pipe: bytes reach the
printer, no reply comes back. Over USB you can send settings and run every
function, but *Receber*, *Obter Status* and the printer-information fields are
unavailable — the app disables them and says why. For full two-way access, use
Ethernet.

## Install

**[⬇ Download the disk image (.dmg) from the latest release](../../releases/latest)**

Open it and drag **L42 Config** wherever you like. There is no installer and
nothing is written outside the app; the only preference it stores is the
printer's IP address.

The app is not signed with an Apple Developer ID, so on first launch macOS will
refuse it: **right-click the app → Open → Open** (or allow it under System
Settings → Privacy & Security).

## Usage

1. Pick the interface in the sidebar — **Ethernet** for full access, **USB**
   for send-only — then enter the IP or choose the print queue.
2. **Receber** reads the current configuration from the printer.
3. Change what you need and click **Enviar**.
4. **Funções → Salvar Configurações na Impressora** writes them to permanent
   memory (`^JUS`). Without this step the changes are lost at power-off.

### Printer settings vs driver defaults

These are two independent layers and it is worth knowing which you are editing:

- **Aba Comum** — stored in the printer itself, applies to every job from any
  computer.
- **Aba Driver (macOS)** — the print queue's defaults on this Mac, i.e. what
  the print dialog shows when it opens.

When a driver option reads **`PD` (Printer Default)** the driver sends nothing
and the printer's stored value wins. Set it to a value and the driver overrides
the printer for that job.

## Build from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```
./build.sh            # builds L42Config.app
./build.sh --dist     # also packs L42Config-<version>.dmg
```

The app is a single Swift file with no dependencies beyond the system
frameworks. `make_icon.py` regenerates the icon.

## How it works

```
L42 Config  ──TCP 9100──>  printer        (Ethernet: send and receive)
            ──lp -o raw──>  CUPS queue    (USB: send only)
```

Configuration is read with `^XA^HH^XZ`, whose reply is a plain-text dump of
every printer setting, and written with ordinary ZPL/PPLZ commands: `~SD`
darkness, `^PR` speed, `^MT` print method, `^MN` + `^JS` media type and sensor,
`^MM` post-print action, `^LT`/`^LS`/`~TA` offsets, `^ML` max calibration
length, `^MF` power-up and head-close actions, `^JU` save/recall/factory.

Firmware update is deliberately **not** implemented: the protocol is
proprietary and a failed write bricks the printer. Use Elgin's Windows utility
if you need it. Network settings are shown read-only for a related reason —
changing the IP over that same connection would cut it; use the printer's own
web page at `http://<ip>`.

## Provenance

Developed with [Claude](https://claude.com/claude-code) and tested against real
hardware (an L42PRO FULL over Ethernet): configuration reads, command
generation, and the USB guard rails were each verified end-to-end. Command
syntax comes from the PPLZ programmer's manual; field names and the parameter
list were checked against Elgin's own utility. The whole app is one Swift file
— audits welcome.

## License

MIT — see [LICENSE](LICENSE).
