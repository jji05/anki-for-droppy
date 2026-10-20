# Anki for Droppy

A Droplet for [Droppy](https://getdroppy.app), built with
[DroppyKit](https://getdroppy.app/docs/droppykit).

## Developing

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce AnkiForDroppy.droplet
droppykit validate   # the checks the Store repository runs
droppykit submit     # open the merge request that puts it in the Store
```

## Before submitting

- Leave `AnkiForDroppy.icon` as it is. It is a placeholder for the harness:
  Jordy designs every Store droplet's icon, and `droppykit submit` leaves it
  out. Have an idea for yours? Put it in the merge request's Icon concept
  section.
- Replace `Assets/Creator.png` with your own square, unrounded mark.
- Fill in `summary`, `description` and `creator` in `droplet.json`, and
  write `CHANGELOG.md`.
- `droppykit submit`: the Store is a repository, one folder per droplet, and
  this opens the merge request that adds yours. See
  [Submitting](https://getdroppy.app/docs/droppykit/submitting).
