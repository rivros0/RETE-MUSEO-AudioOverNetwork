#!/usr/bin/env python3
"""Distribuisce via SSH il setup Roc Museum, un Raspberry alla volta."""

import argparse
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def destinazione(value):
    if not re.fullmatch(r"(?:[a-zA-Z0-9_][a-zA-Z0-9_.-]*@)?[a-zA-Z0-9_][a-zA-Z0-9_.-]*", value):
        raise argparse.ArgumentTypeError("Usare un hostname o IPv4, eventualmente preceduto da utente@")
    return value


def esegui(command, dry_run=False):
    if dry_run:
        print("  " + shlex.join(command), flush=True)
    else:
        subprocess.run(command, check=True)


def aggiorna(host, setup, port, identity, dry_run):
    options = ["-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
               "-o", "ServerAliveCountMax=3"]
    if identity:
        options += ["-i", str(identity)]
    ssh = ["ssh", *options, "-p", str(port), host]
    # mktemp evita collisioni e file temporanei prevedibili sul Raspberry.
    if dry_run:
        remote_dir = "/tmp/roc-museum.XXXXXXXX"
    else:
        result = subprocess.run([*ssh, "mktemp -d /tmp/roc-museum.XXXXXXXX"],
                                check=True, text=True, capture_output=True)
        remote_dir = result.stdout.strip()
        if not re.fullmatch(r"/tmp/roc-museum\.[a-zA-Z0-9]+", remote_dir):
            raise RuntimeError("Percorso temporaneo remoto non valido")
    remote_file = remote_dir + "/setup_roc_museum.sh"
    try:
        esegui(["scp", *options, "-P", str(port), str(setup),
                host + ":" + remote_file], dry_run)
        # Il wizard originale mantiene ruolo/nome/IP e gestisce sudo e reboot
        # tramite il terminale SSH. Il backup precede qualsiasi modifica.
        script = r'''
set -eu
backup=$(mktemp -d /var/backups/roc-museum-$(date +%Y%m%d-%H%M%S).XXXXXXXX)
for file in /etc/roc-museum.conf /etc/systemd/system/roc-museum.service /etc/systemd/system/roc-museum-monitor.service /usr/local/sbin/roc-museum-run /usr/local/sbin/roc-museum-monitor /usr/local/lib/roc-museum /usr/local/share/roc-museum /var/lib/roc-museum/auth.json /var/lib/roc-museum/volume /boot/firmware/config.txt /boot/config.txt; do
    if [ -e "$file" ]; then cp -a --parents "$file" "$backup/"; fi
done
# Backup SQLite coerente anche con il calendario attivo. La libreria audio
# resta sul posto: duplicarla potrebbe esaurire la microSD durante l'update.
python3 - "$backup" <<'PY_BACKUP'
import pathlib, sqlite3, sys
source=pathlib.Path('/var/lib/roc-museum/studio/calendar.sqlite')
if source.exists():
    target=pathlib.Path(sys.argv[1])/source.relative_to('/')
    target.parent.mkdir(parents=True,exist_ok=True)
    original=sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)
    backup=sqlite3.connect(target)
    try: original.backup(backup)
    finally: backup.close();original.close()
PY_BACKUP
printf '\nBackup salvato in: %s\n' "$backup"
bash "$1"
printf '\nVerifica finale dei servizi\n'
sleep 3
systemctl is-active roc-museum.service
systemctl is-active roc-museum-monitor.service
'''
        command = "sudo bash -c " + shlex.quote(script) + " bash " + shlex.quote(remote_file)
        esegui([*ssh[:-1], "-t", host, command], dry_run)
    finally:
        # Se il wizard riavvia il nodo, la pulizia avverrà al riavvio di /tmp
        # dove previsto dal sistema; un errore di pulizia non maschera l'esito.
        if not dry_run:
            try:
                subprocess.run([*ssh, "rm -f -- " + shlex.quote(remote_file) +
                                "; rmdir " + shlex.quote(remote_dir)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=25, check=False)
            except (subprocess.SubprocessError, OSError):
                print("Avviso: impossibile rimuovere il temporaneo " + remote_dir,
                      file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hosts", nargs="*", type=destinazione,
                        help="Raspberry da aggiornare: utente@IP o hostname")
    parser.add_argument("--setup", type=Path,
                        default=Path(__file__).resolve().with_name("setup_roc_museum.sh"))
    parser.add_argument("--port", type=int, default=22, help="Porta SSH (default: 22)")
    parser.add_argument("--identity", type=Path, help="Chiave privata SSH")
    parser.add_argument("--dry-run", action="store_true", help="Mostra i comandi senza collegarsi")
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error("Porta SSH fuori intervallo")
    if not args.setup.is_file():
        parser.error("Installer non trovato: " + str(args.setup))
    if args.identity and not args.identity.is_file():
        parser.error("Chiave SSH non trovata")
    if any(shutil.which(tool) is None for tool in ("ssh", "scp")):
        parser.error("Installare i client ssh e scp sul computer locale")
    if not args.hosts:
        if not sys.stdin.isatty():
            parser.error("Indicare almeno un Raspberry")
        try:
            args.hosts = [destinazione(value) for value in
                          input("Raspberry (utente@IP), separati da spazi: ").split()]
        except argparse.ArgumentTypeError as error:
            parser.error(str(error))
        if not args.hosts:
            parser.error("Nessun Raspberry indicato")
    print("Aggiornamento Roc Museum: breve interruzione audio su ciascun nodo.")
    print("Nel wizard premere Invio per mantenere la configurazione esistente.", flush=True)
    for host in dict.fromkeys(args.hosts):
        print("\n=== " + host + " ===", flush=True)
        try:
            aggiorna(host, args.setup.resolve(), args.port, args.identity, args.dry_run)
        except (subprocess.SubprocessError, OSError, RuntimeError) as error:
            print("Aggiornamento interrotto su " + host + ": " + str(error), file=sys.stderr)
            print("Gli altri nodi non vengono aggiornati. Se hai richiesto un reboot, "
                  "verifica i servizi dopo la riconnessione.", file=sys.stderr)
            return 1
        print("Simulazione completata." if args.dry_run else "Servizi attivi su " + host, flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        sys.exit("Operazione interrotta.")
