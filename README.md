# CUPS Print Server (LPD) — Home Assistant add-on

CUPS print server for Home Assistant OS with an extra **LPD gateway on port 515**,
so Android apps such as **PrinterShare** can print to a USB printer attached to the HA host.

Based on [arest/cups-addon](https://github.com/arest/cups-addon) (Apache-2.0).

## What's added
- LPD receiver (RFC 1179) on port 515 that accepts PrinterShare's streamed jobs
  (data length `2147483647`, empty queue name, `printers/<name>` queue prefix).
- Jobs of type `l` are passed to CUPS as raw (`lp -o raw`); other types go through CUPS filters.
- Empty queue name → CUPS default printer.

## Install
1. Settings → Add-ons → Add-on store → ⋮ → Repositories → add
   `https://github.com/Rsa76d/Print-ha-cups-lpd`
2. Install **CUPS Print Server (LPD)**, start it.
3. Open `http://<HA-IP>:631`, add the printer, set it as default.
4. In PrinterShare choose the printer found via Bonjour / LPD.

Ports: 631 (IPP/web UI), 515 (LPD).
