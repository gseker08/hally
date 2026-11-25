# Ekransız aktivite önerileri ("Şimdi ne yapsam?")

When the child's screen time runs out, the lock page on the child's phone shows a "Şimdi ne yapsam?" card. It opens a
list of screen-free ideas picked by the child's age and the weather; "Yaptım" earns cherries through the usual parent
approval (`ChildClaim` with kind `Activity`).

## Ideas

- **Built-in** (`ActivityCatalog`): 26 ideas, Turkish and English, each with an age range, indoor/outdoor, minutes and
  cherries (2–5). Ids are derived from a stable key, so they never change.
- **The family's own** (`FamilyActivity`): parents add up to 30 (title, emoji, 1–10 cherries, indoor/outdoor). They are
  shown to every child of the family, first.
- Age comes from the child's birth year; without one every idea is shown.
- The order is shuffled per child per day (stable during the day, new tomorrow).

## Weather

Optional. A parent picks a city (`PUT families/{f}/weather-place`, search via `GET weather/places?q=`); only the city
name and its point rounded to 0.1° (about 10 km) are stored. The server asks Open-Meteo (no key) for the current
weather, cached for 30 minutes per city. Rain, snow, storm, dark, below 5 °C or above 33 °C → indoor ideas only; nice
weather → outdoor ideas first. No city or a failed lookup → indoor and outdoor mixed, no weather pill.

## Cherries

- `POST child/activities/{id}/done?lang=tr` → pending claim (or straight to the jar with approval off). The title is
  saved in the child's language.
- One claim per idea per day; at most 3 ideas a day (422 `activity.daily_limit`).
- Approved ideas add a `PointKind.Activity` entry; those days count for the 7-day streak like chores and habits.

## Endpoints

| | |
|---|---|
| `GET api/v1/child/activities?lang=` | child phone: weather, age, today's count, ideas with state Todo/Pending/Done |
| `POST api/v1/child/activities/{id}/done?lang=` | child phone: "Yaptım" |
| `GET/POST api/v1/families/{f}/activities`, `DELETE …/{id}` | parents: the family's own ideas |
| `PUT api/v1/families/{f}/weather-place` | parents: city (null name clears) |
| `GET api/v1/weather/places?q=&lang=` | signed-in adults: city search |
