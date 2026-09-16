"""Run with the bot requirements installed; no Telegram calls are made."""
import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "mtproxyl-tgbot"))
from bot import config, keyboards, notify


class DCNotifications(unittest.IsolatedAsyncioTestCase):
    async def test_zero_transition_and_recovery_without_coverage_alerts(self):
        cfg = config.Config()
        report = {"available": True, "threshold": 0, "dcs": [
            {"dc": 1, "required_writers": 10, "alive_writers": 0}]}
        state = {}
        with patch.object(notify.cli, "dc_status", AsyncMock(return_value=report)), \
             patch.object(notify.config, "load", return_value=cfg), \
             patch.object(notify, "broadcast", AsyncMock()) as broadcast:
            await notify.check_dc(None, state)
            await notify.check_dc(None, state)
            self.assertEqual(broadcast.await_count, 1)
            report["dcs"][0]["alive_writers"] = 1
            await notify.check_dc(None, state)
            self.assertEqual(broadcast.await_count, 2)
            cfg.notify["dc_zero"] = False
            report["dcs"][0]["alive_writers"] = 0
            await notify.check_dc(None, state)
            self.assertEqual(broadcast.await_count, 2)

    async def test_zero_alert_is_independent_from_coverage_alert(self):
        cfg = config.Config()
        cfg.notify["dc"] = False
        report = {"available": True, "threshold": 80, "coverage_pct": 0, "dcs": [
            {"dc": 2, "required_writers": 5, "alive_writers": 0}]}
        state = {}
        with patch.object(notify.cli, "dc_status", AsyncMock(return_value=report)), \
             patch.object(notify.config, "load", return_value=cfg), \
             patch.object(notify, "broadcast", AsyncMock()) as broadcast:
            await notify.check_dc(None, state)
            self.assertEqual(broadcast.await_count, 1)
            self.assertNotIn("dc_bad", state)

    def test_settings_controls(self):
        cfg = config.Config()
        buttons = [b.callback_data for row in keyboards.settings_menu(cfg, False).inline_keyboard for b in row]
        self.assertIn("s:toggle:dc", buttons)
        self.assertIn("s:toggle:dc_zero", buttons)
        intervals = [b.callback_data for row in keyboards.intervals_menu(cfg).inline_keyboard for b in row]
        self.assertIn("s:int:dc", intervals)


if __name__ == "__main__":
    unittest.main()
