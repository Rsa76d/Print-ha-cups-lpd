#!/bin/sh
# LPD front-end for the cups_lpd add-on (one connection per run, started by
# socat with the client socket on stdin/stdout).
#
# lpd10: "receive job" (code 02) is handled here instead of cups-lpd, because
# PrinterShare sends the data file with length 2147483647 = "until the
# connection closes", which cups-lpd does not support (it waits for 2 GB and
# answers 01). Received files are submitted with lp. Status / remove
# requests (codes 01, 03-05) still go to cups-lpd.
#
# History: lpd2 strip "printers/" from the queue name (Bonjour rp=printers/X);
# lpd5 empty queue name -> CUPS default printer (or the first printer);
# lpd7 CUPS_SERVER = local socket; lpd8/lpd9 streaming fixes.

log() { echo "lpd-wrapper[$$] $(date +%H:%M:%S): $*" >&2; }

for sock in /run/cups/cups.sock /var/run/cups/cups.sock; do
    if [ -S "$sock" ]; then CUPS_SERVER=$sock; break; fi
done
export CUPS_SERVER=${CUPS_SERVER:-127.0.0.1:631}

# Single-byte replies written by separate processes: nothing can sit in a
# shell buffer.
ack() { head -c 1 /dev/zero; }
nak() { printf '\001' > "$work/nak"; cat "$work/nak"; }

work=$(mktemp -d /tmp/lpd.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 143' TERM HUP INT

# ---- first line: <code><queue>[ <args>] -----------------------------------
if ! IFS= read -r -t 30 line; then
    log "no complete command line within 30 s"
    exit 1
fi
rest=${line#?}
cmd=${line%"$rest"}
code=$(printf '%s' "$cmd" | od -An -tx1 | tr -d ' ')
log "request: code=$code queue/args='$rest'"
rest=${rest#printers/}

if [ -z "${rest%% *}" ]; then
    def=$(lpstat -d 2>/dev/null | sed -n 's/^.*destination: *//p')
    [ -n "$def" ] || def=$(lpstat -a 2>/dev/null | head -n 1 | cut -d ' ' -f 1)
    if [ -n "$def" ]; then
        log "empty queue name -> using '$def'"
        rest="$def$rest"
    fi
fi
queue=${rest%% *}

# ---- everything except "receive job": let cups-lpd answer -----------------
if [ "$code" != "02" ]; then
    printf '%s%s\n' "$cmd" "$rest" > "$work/req"
    /usr/lib/cups/daemon/cups-lpd -n < "$work/req"
    rc=$?
    log "cups-lpd (code $code) rc=$rc"
    exit "$rc"
fi

# ---- receive job ----------------------------------------------------------
if [ -z "$queue" ] || ! lpstat -a "$queue" >/dev/null 2>&1; then
    log "unknown or not accepting queue '$queue' -> reject"
    nak
    exit 1
fi
ack

ndata=0
streamed=0
while IFS= read -r sub; do
    args=${sub#?}
    sc=$(printf '%s' "${sub%"$args"}" | od -An -tx1 | tr -d ' ')
    count=${args%% *}
    name=${args#* }
    case "$sc" in
        01)                                     # abort job
            log "client aborted the job"
            exit 0 ;;
        02|03)
            case "$count" in ''|*[!0-9]*) log "bad subcommand '$sub'"; nak; exit 1 ;; esac
            if [ "$sc" = 02 ]; then f="$work/control"; else ndata=$((ndata + 1)); f="$work/data$ndata"; fi
            ack
            if [ "$sc" = 03 ] && { [ "$count" -eq 0 ] || [ "$count" -ge 2000000000 ]; }; then
                # Length unknown: data runs until the client closes its side.
                cat > "$f"
                streamed=1
                log "data file '$name': streamed, $(wc -c < "$f") bytes"
                break
            fi
            head -c "$count" > "$f"
            got=$(wc -c < "$f")
            if [ "$got" -ne "$count" ]; then
                log "file '$name': expected $count bytes, got $got"
                nak; exit 1
            fi
            head -c 1 > /dev/null               # trailing NUL
            ack
            log "file '$name' ($sc): $count bytes" ;;
        *)
            log "unknown subcommand '$sub'"
            nak; exit 1 ;;
    esac
done

if [ "$ndata" -eq 0 ]; then
    log "no data file received"
    [ "$streamed" = 1 ] && nak
    exit 1
fi

# ---- control file: user, title, file type ---------------------------------
user=lpd; title=; ftype=l
if [ -f "$work/control" ]; then
    u=$(sed -n 's/^P//p' "$work/control" | head -n 1 | tr -cd '[:alnum:]._-')
    [ -n "$u" ] && user=$u
    title=$(sed -n 's/^J//p' "$work/control" | head -n 1)
    [ -n "$title" ] || title=$(sed -n 's/^N//p' "$work/control" | head -n 1)
    t=$(grep -m 1 '^[a-z]' "$work/control" | cut -c1)
    [ -n "$t" ] && ftype=$t
fi

# 'l' = print as-is (PrinterShare renders with its own driver) -> raw.
# Anything else: let CUPS detect the format and run its filters.
set --
[ "$ftype" = l ] && set -- -o raw

rc=0
i=1
while [ "$i" -le "$ndata" ]; do
    if out=$(lp -d "$queue" -U "$user" -t "${title:-LPD job}" "$@" "$work/data$i" 2>&1); then
        log "submitted to '$queue' (type $ftype, user $user): $out"
    else
        log "lp failed: $out"
        rc=1
    fi
    i=$((i + 1))
done

# Clients that stream the data wait for one final status byte.
if [ "$streamed" = 1 ]; then
    if [ "$rc" -eq 0 ]; then ack; else nak; fi
fi
exit "$rc"
