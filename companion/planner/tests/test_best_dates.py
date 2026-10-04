"""Best period for a trip without dates. Synthetic route, closures and weather history only (no network)."""
import asyncio
import datetime as dt

import httpx

from app.best_dates import best_periods, sunset_hour


def north_track(km: float) -> list[dict[str, float]]:
    return [{"lat": 44.0 + i * 0.001, "lon": 6.0} for i in range(int(km * 1000 / 111) + 1)]


TRIP = {"params": {"flexibleDates": True, "dateStart": "2027-03-01", "dateEnd": "2027-03-02"},
        "days": [{"index": 1, "drivingTimeMin": 120, "track": {"points": north_track(5)}},
                 {"index": 2, "drivingTimeMin": 150, "track": {"points": north_track(5)}}]}
WINTER_ROAD = {"points": [(44.010, 6.0), (44.015, 6.0), (44.020, 6.0)], "periods": [(11, 1, 4, 30)], "road": "D 900"}
PASS = {"lat": 44.016, "lon": 6.0005, "name": "Col test", "ele": 2000}


def fake_archive(calls):
    """Rain every day of May and October, 34 °C in July and August, mild otherwise."""
    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.params["start_date"])
        start = dt.date.fromisoformat(request.url.params["start_date"])
        end = dt.date.fromisoformat(request.url.params["end_date"])
        days = [start + dt.timedelta(days=i) for i in range((end - start).days + 1)]
        return httpx.Response(200, json={"daily": {
            "time": [d.isoformat() for d in days],
            "precipitation_sum": [6.0 if d.month in (5, 10) else 0.0 for d in days],
            "temperature_2m_min": [10.0] * len(days),
            "temperature_2m_max": [34.0 if d.month in (7, 8) else 22.0 for d in days]}})
    return handler


def run(tmp_path, calls):
    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(fake_archive(calls))) as client:
            return await best_periods(TRIP, [WINTER_ROAD], [PASS], client, tmp_path, today=dt.date(2027, 1, 1))
    return asyncio.run(go())


def test_three_open_dry_mild_periods_far_enough_apart(tmp_path):
    calls = []
    options = run(tmp_path, calls)
    assert len(options) == 3
    starts = [dt.date.fromisoformat(o["start"]) for o in options]
    assert all(s.month in (6, 9) for s in starts)                  # not closed, not rainy, not hot
    assert all(abs((a - b).days) >= 10 for i, a in enumerate(starts) for b in starts[i + 1:])
    first = options[0]
    assert dt.date.fromisoformat(first["end"]) - dt.date.fromisoformat(first["start"]) == dt.timedelta(days=1)
    assert first["label"].startswith("Du ")
    assert any("ouverts" in r for r in first["reasons"]) and any("Pluie 0 jour" in r for r in first["reasons"])
    assert len(calls) == 1                                         # both stages share the place: one request


def test_history_is_cached_on_disk(tmp_path):
    run(tmp_path, [])
    calls = []
    run(tmp_path, calls)
    assert calls == []


def test_sunset_follows_the_season_and_the_longitude():
    june, december = dt.date(2027, 6, 21), dt.date(2027, 12, 21)
    assert sunset_hour(45.0, 5.0, june) - sunset_hour(45.0, 5.0, december) > 3
    # 15° further east, same legal time: the sun sets about an hour earlier.
    assert 0.9 < sunset_hour(45.0, 0.0, june) - sunset_hour(45.0, 15.0, june) < 1.1
