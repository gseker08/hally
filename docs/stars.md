# Chore stars and rewards

Parents set **chores** worth stars and **rewards** that cost stars. The child earns stars when a parent ticks a chore and spends
them on a reward: pocket money, a trip to the park, an extra story. Hally does not handle money; "20 TL harçlık" is just a reward's name.

## Rules

- A chore is worth 1–50 stars and is either for every child or for one child.
- A chore counts **once per child per family-local day**, even when both parents tick it (a partial unique index on chore, child, day).
- A reward costs 1–1000 stars. Getting it needs enough stars (422 `points.not_enough` otherwise); the balance check runs in a serializable transaction.
- The balance is the sum of the child's ledger: plus for chores, minus for rewards. Any line can be undone.
- Deleting a chore or reward keeps the stars already earned or spent; the ledger keeps the title.

## API

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/v1/families/{familyId}/points` | Chores, rewards, and per child: balance, stars this week, chores done today (chore → entry) |
| GET | `.../children/{childId}/points` | Latest 50 ledger lines |
| POST / PUT / DELETE | `.../chores[/{choreId}]` | `{ title, points, childId? }` |
| POST / DELETE | `.../rewards[/{rewardId}]` | `{ title, cost }` |
| POST | `.../children/{childId}/chores/{choreId}/done` | Idempotent for the day; returns the board |
| POST | `.../children/{childId}/rewards/{rewardId}/redeem` | Returns the board |
| DELETE | `.../children/{childId}/points/{entryId}` | Undo; returns the board |

Every change sends `PointsChanged { familyId }` over `/hubs/chat`.
