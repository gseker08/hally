# Child profile photos

A child can have an optional profile photo. It replaces the initial in every child badge (Kids tab, task and event
tags, filters, trackers); the child's colour stays as a ring around it. Without a photo the initial shows as before.

## App

- Child add/edit sheet: tap the round photo area → camera, gallery or (when there is one) remove.
- After picking, a full-screen page lets the parent zoom and move the photo inside a circle. The app uploads a
  384×384 PNG of that square, so uploads are small.
- For a new child the photo is uploaded right after the child is created. If only the photo fails, the child stays
  saved and the sheet says so.

## API

| Method | Path | Notes |
| --- | --- | --- |
| PUT | `/api/v1/families/{familyId}/children/{childId}/photo` | multipart `file` (JPEG, PNG, WebP or HEIC, up to 5 MB; the type is read from the bytes). Returns the child. Replaces and deletes any previous photo. |
| GET | `/api/v1/families/{familyId}/children/{childId}/photo?v=…` | The decrypted photo. Family members only. Cached as immutable: the `v` changes with every new photo. |
| DELETE | `/api/v1/families/{familyId}/children/{childId}/photo` | Removes it. Returns the child. |

`ChildDto.photoUrl` is the relative URL above (with `v`), or null.

## Storage and privacy

Photos are stored with the same AES-256-GCM document store as captures and chat photos. They are deleted when the
photo is replaced or removed, when the child is deleted, and when the family is deleted (last adult leaves or deletes
their account).
