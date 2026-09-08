# Firestore configuration

Deploy from this directory:

```sh
firebase deploy --only firestore:rules,firestore:indexes
```

## Indexes

`commands` is queried by the hub as `status == "pending"` ordered by
`requested_at`, which needs the composite index. `system_logs` carries the
index the previous system used.

## The fcm_tokens field override

Left over from the previous FlutterFlow app, which delivered notifications
through FCM. This system pushes directly to APNs from the hub instead, so
nothing reads that index any more — it is recorded here only so that a
deploy does not report drift against the project, and so that removing it
later is a deliberate act rather than a `--force` someone runs to silence a
warning they did not understand.
