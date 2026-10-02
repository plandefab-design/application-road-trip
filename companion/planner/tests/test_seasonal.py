"""Seasonal checks done by the PC instead of the planner. Synthetic roads and passes only."""
import asyncio
import datetime as dt

import httpx

from app.alerts import TrackIndex
from app.seasonal import (CLOSURE_MARK, WEATHER_MARK, closure_periods, closure_warnings, is_closed, season_weather,
                          seasonal_checks, weather_line)


def test_closure_periods_from_osm_conditions():
    assert closure_periods("no @ (Oct 20-May 31)") == [(10, 20, 5, 31)]
    assert closure_periods("no @ (Nov-Apr)") == [(11, 1, 4, 30)]
    assert closure_periods("no @ (Dec-Feb)") == [(12, 1, 2, 28)]
    assert closure_periods("destination @ (Nov-Apr); no @ (Nov 15 - May 15)") == [(11, 15, 5, 15)]
    assert closure_periods("no @ snow") == [] and closure_periods("") == []


def test_closed_across_the_new_year():
    winter = (10, 20, 5, 31)
    assert is_closed(winter, dt.date(2027, 1, 10)) and is_closed(winter, dt.date(2027, 5, 31))
    assert not is_closed(winter, dt.date(2027, 6, 1)) and not is_closed(winter, dt.date(2027, 10, 19))
    assert is_closed((6, 1, 6, 30), dt.date(2027, 6, 15)) and not is_closed((6, 1, 6, 30), dt.date(2027, 7, 1))


def north_track(km: float) -> list[dict[str, float]]:
    return [{"lat": 44.0 + i * 0.001, "lon": 6.0} for i in range(int(km * 1000 / 111) + 1)]


CLOSED_ROAD = {"points": [(44.010, 6.0), (44.015, 6.0), (44.020, 6.0)], "periods": [(10, 20, 5, 31)], "road": "D 900"}
CROSSING_ROAD = {"points": [(44.030, 5.99), (44.030, 6.0), (44.030, 6.01)], "periods": [(11, 1, 4, 30)], "road": "D 901"}
PASS = {"lat": 44.016, "lon": 6.0005, "name": "Col test", "ele": 2000}


def test_a_closed_road_on_the_route_is_reported_with_its_pass():
    index = TrackIndex(north_track(5))
    lines = closure_warnings(index, dt.date(2027, 5, 20), [CLOSED_ROAD, CROSSING_ROAD], [PASS])
    assert len(lines) == 1                                       # the crossing road is not used by the route
    assert lines[0].startswith(CLOSURE_MARK + "Col test (D 900) : fermé du 20 oct. au 31 mai")
    assert "tombe dedans" in lines[0]
    assert closure_warnings(index, dt.date(2027, 8, 1), [CLOSED_ROAD], [PASS]) == []
    near = closure_warnings(index, dt.date(2027, 6, 8), [CLOSED_ROAD], [PASS])
    assert len(near) == 1 and "proche" in near[0]


def test_weather_line_only_when_the_season_needs_it():
    day = dt.date(2027, 6, 12)
    assert weather_line(2, day, "Col test", {"rain": 0.1, "low": 12, "high": 26}) is None
    line = weather_line(2, day, "Col test", {"rain": 0.42, "low": 3.6, "high": 18})
    assert line == (WEATHER_MARK + "Météo de saison, jour 2 (12 juin, Col test) : pluie 4 jours sur 10, "
                    "4 °C au petit matin (Open-Meteo, 10 dernières années).")


def test_season_weather_from_ten_years_of_archive():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.params["start_date"])
        return httpx.Response(200, json={"daily": {"precipitation_sum": [0, 0, 5, 0, 0, 2, 0],
                                                   "temperature_2m_min": [4] * 7, "temperature_2m_max": [20] * 7}})

    async def run():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await season_weather(44.0, 6.0, dt.date(2027, 6, 12), client)

    w = asyncio.run(run())
    assert len(calls) == 10 and "2017-06-09" in calls and "2026-06-09" in calls
    assert round(w["rain"], 2) == round(2 / 7, 2) and w["low"] == 4 and w["high"] == 20


def test_checks_replace_the_previous_pc_lines_and_keep_the_planners():
    trip = {"params": {"dateStart": "2027-05-20"},
            "mustCheck": ["Réserver le refuge", CLOSURE_MARK + "ancienne ligne"],
            "days": [{"index": 1, "track": {"points": north_track(5)}}]}
    lines = asyncio.run(seasonal_checks(trip, [CLOSED_ROAD], [PASS], weather=False))
    assert len(lines) == 1
    assert trip["mustCheck"] == ["Réserver le refuge", lines[0]]
    asyncio.run(seasonal_checks(trip, [CLOSED_ROAD], [PASS], weather=False))
    assert trip["mustCheck"] == ["Réserver le refuge", lines[0]]        # run again: same lines, no duplicate
