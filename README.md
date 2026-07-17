## Logs

Ferri logs through macOS unified logging (subsystem `eu.monniot.Ferri`), so they're retrievable even after launching the app by double-clicking it in Finder. View them in Console.app (filter by subsystem), or from a terminal:

```sh
log show --predicate 'subsystem == "eu.monniot.Ferri"' --last 1h
log stream --predicate 'subsystem == "eu.monniot.Ferri"'
```
