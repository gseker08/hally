# Health card

One card per child with what parents are asked for again and again: at the doctor's, at school, by a babysitter.
Hally keeps what the parents enter and gives **no medical advice**: no vaccine schedule, no percentiles, no judgement on growth.

## Parts

- **Basics** (one per child): blood type (0+, 0-, A+, A-, B+, B-, AB+, AB-), allergies, ongoing conditions, doctor's name and phone
  (tap to call), notes. Both parents saving the first version at once is handled (unique index on child, retry on top).
- **Vaccines**: a name and either a due date (planned, from the doctor's card) or the date it was given. Planned ones come first,
  soonest first; a planned one past its date shows as overdue (orange). "Yapıldı" marks it given today.
- **Growth**: height (30–220 cm), weight (0.5–200 kg) and/or head size (20–70 cm) on a day, not in the future. The app draws a
  small height line when there are two or more heights.
- **Appointments**: an ordinary calendar event tagged with the child (one hour), plus a row that marks it as a health appointment
  and keeps the doctor's name. So it shows on the calendar and in Today. By default every adult gets a reminder at 19:00 family
  time the evening before (or 2 hours before, if the evening has passed). Deleting it here deletes the event; deleting the event
  on the calendar removes it here too (cascade).

## API

Base: `/api/v1/families/{familyId}/children/{childId}/health`. Every call returns the whole card.

| Method | Path | Notes |
| --- | --- | --- |
| GET | `` | `{ childId, profile, vaccines, growth (oldest first), appointments (upcoming, then last 5 past) }` |
| PUT | `/profile` | `{ bloodType?, allergies?, conditions?, doctorName?, doctorPhone?, notes? }` |
| POST / PUT / DELETE | `/vaccines[/{id}]` | `{ name, dueOn?, givenOn?, note? }`; one of the dates is required |
| POST | `/vaccines/{id}/given` | `{ on? }` (default today) |
| POST / DELETE | `/growth[/{id}]` | `{ heightCm?, weightKg?, headCm?, measuredOn? }` |
| POST / DELETE | `/appointments[/{id}]` | `{ title, startsAt, location?, doctor?, remind = true }` |

Every change sends `HealthChanged { familyId, childId }` over `/hubs/chat`. Medications stay on their own page (`docs/medications.md`);
the card links to it.
