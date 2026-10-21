# useful-scripts

Small shell scripts for managing this Ubuntu server.

## sleep-settings.sh

Show or change whether the machine can sleep, suspend or hibernate. Use it to keep the server reachable 24/7.

```bash
./sleep-settings.sh status                    # show current settings (no sudo)
./sleep-settings.sh disable                   # keep the machine awake (sudo)
./sleep-settings.sh enable                    # restore default sleep behaviour (sudo)
./sleep-settings.sh disable --restart-logind  # also apply logind changes now
```

`disable` does two things:

- It masks the systemd sleep targets (`sleep`, `suspend`, `hibernate`, `hybrid-sleep`, `suspend-then-hibernate`). This blocks every kind of sleep and takes effect immediately.
- It writes `/etc/systemd/logind.conf.d/99-no-sleep.conf`, which tells logind to ignore lid closes, suspend/hibernate keys and idle. These settings apply after a reboot, or right away with `--restart-logind`. Restarting logind can end desktop sessions; SSH sessions normally survive.

`enable` reverses both changes.
