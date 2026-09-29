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

    async def test_engine_restart_is_reported_once(self):
        cfg = config.Config()
        auto = {"enabled": True, "threshold": 50, "cooldown_min": 5, "pause_min": 5,
                "restarts": 1, "last_restart_at": 1000, "last_restart_coverage": 30}
        report = {"available": False, "auto_restart": auto, "dcs": []}
        state = {}
        with patch.object(notify.cli, "dc_status", AsyncMock(return_value=report)), \
             patch.object(notify.config, "load", return_value=cfg), \
             patch.object(notify, "broadcast", AsyncMock()) as broadcast:
            # Перезапуск до запуска бота — не новость.
            await notify.check_dc(None, state)
            self.assertEqual(broadcast.await_count, 0)
            auto["last_restart_at"] = 2000
            await notify.check_dc(None, state)
            await notify.check_dc(None, state)
            self.assertEqual(broadcast.await_count, 1)
            self.assertIn("30%", broadcast.await_args.args[1])

    def test_dc_menu_and_text(self):
        from bot import format as fmt
        buttons = [b.callback_data for row in keyboards.dc_menu(False).inline_keyboard for b in row]
        self.assertEqual(buttons, ["dc:show", "dc:ar", "dc:thr", "dc:cool", "m:root"])
        self.assertIn("выключен", fmt.dc_restart_text({"enabled": False}))
        text = fmt.dc_restart_text({"enabled": True, "threshold": 40, "cooldown_min": 7,
                                    "last_restart_at": 1000, "last_restart_coverage": 20, "restarts": 2})
        self.assertIn("ниже 40%", text)
        self.assertIn("при покрытии 20%", text)
        self.assertEqual(fmt.dc_restart_text({}), "")

    def test_settings_controls(self):
        cfg = config.Config()
        buttons = [b.callback_data for row in keyboards.settings_menu(cfg, False).inline_keyboard for b in row]
        self.assertIn("s:toggle:dc", buttons)
        self.assertIn("s:toggle:dc_zero", buttons)
        intervals = [b.callback_data for row in keyboards.intervals_menu(cfg).inline_keyboard for b in row]
        self.assertIn("s:int:dc", intervals)


if __name__ == "__main__":
    unittest.main()
