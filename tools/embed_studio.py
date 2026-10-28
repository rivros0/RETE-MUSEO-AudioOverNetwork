#!/usr/bin/env python3
"""Regenerate the standalone installer after editing studio.py or studio.html."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
path=root/'setup_roc_museum.sh'
text=path.read_text()
for marker,name in (('PY_UPDATER','updater.py'),('PY_STUDIO','studio.py'),('HTML_STUDIO','studio.html'),('PY_AUDIO_BUS','audio_bus.py'),('SH_REMOTE','remote_access.sh'),('WATCHDOG_0', 'vendor/funnel-watchdog/README.md'),('WATCHDOG_1', 'vendor/funnel-watchdog/UPSTREAM'),('WATCHDOG_3', 'vendor/funnel-watchdog/deploy/check-tailscale-funnel.sh'),('WATCHDOG_4', 'vendor/funnel-watchdog/deploy/tailscale-funnel-watchdog.service'),('WATCHDOG_5', 'vendor/funnel-watchdog/deploy/tailscale-funnel-watchdog.timer'),('WATCHDOG_6', 'vendor/funnel-watchdog/deploy/tailscale-funnel.logrotate'),('WATCHDOG_8', 'vendor/funnel-watchdog/scripts/install.sh')):
    opening="<<'"+marker+"'\n"
    start=text.index(opening)+len(opening)
    end=text.index('\n'+marker+'\n',start)
    text=text[:start]+(root/name).read_text().rstrip('\n')+text[end:]
path.write_text(text)
