#!/usr/bin/env python3
"""The chunk-join check must still catch a missing space, and must ignore a forecast URL."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import real_host_check as check  # noqa: E402

FORECAST = (
    "Grok: [National Weather Service](https://forecast.weather.gov/MapClick.php?CityName=Argyle&state=TX)"
)


class GlueCheckTests(unittest.TestCase):
    def test_a_missing_space_after_a_period_is_a_join(self) -> None:
        match = check.glued_join("Grok: I'll check: Argyle Texas.Pulling a few readings first.")
        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(match.group(0), "s.Pu")

    def test_a_missing_space_after_a_question_mark_is_a_join(self) -> None:
        match = check.glued_join("Grok: Are you up?City forecasts follow.")
        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(match.group(0), "p?Ci")

    def test_a_forecast_link_is_not_a_join(self) -> None:
        self.assertIsNotNone(check.GLUED_SENTENCE.search(FORECAST))
        self.assertIsNone(check.glued_join(FORECAST))
        self.assertIsNone(check.glued_join("Grok: MapClick.php?CityName=Argyle and then clear."))
        self.assertIsNone(check.glued_join("Grok: see www.weather.gov/MapClick.php?CityName=Argyle today."))

    def test_a_lat_lon_link_does_not_match_the_pattern(self) -> None:
        line = "Grok: https://forecast.weather.gov/MapClick.php?lat=33.1&lon=-97.1"
        self.assertIsNone(check.GLUED_SENTENCE.search(line))
        self.assertIsNone(check.glued_join(line))

    def test_a_link_does_not_hide_a_later_join(self) -> None:
        line = FORECAST + " Texas.Pulling a few readings first."
        match = check.glued_join(line)
        self.assertIsNotNone(match)
        assert match is not None
        self.assertEqual(match.group(0), "s.Pu")


if __name__ == "__main__":
    unittest.main()
