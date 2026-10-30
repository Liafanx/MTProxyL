"""Скоро лимит и отчёт за неделю. Нужны зависимости бота; в Telegram не ходит."""
import sys
import unittest
from datetime import date, datetime, timedelta
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "mtproxyl-tgbot"))
from bot import notify  # noqa: E402

GB = 1024 ** 3


def user(label, used=0, quota=0, expires="0", enabled=True):
    return {"label": label, "total_bytes": used, "quota_bytes": quota,
            "expires": expires, "enabled": enabled}


class LimitsSoon(unittest.IsolatedAsyncioTestCase):
    def test_reasons(self):
        today = date(2026, 10, 30)
        self.assertIn("quota", notify._soon_reasons(user("a", 85 * GB, 100 * GB), today))
        self.assertNotIn("quota", notify._soon_reasons(user("a", 100 * GB, 100 * GB), today))
        self.assertNotIn("quota", notify._soon_reasons(user("a", 10 * GB, 100 * GB), today))
        self.assertIn("expiry", notify._soon_reasons(user("a", expires="2026-11-02"), today))
        self.assertNotIn("expiry", notify._soon_reasons(user("a", expires="2026-11-10"), today))
        self.assertNotIn("expiry", notify._soon_reasons(user("a", expires="2026-10-29"), today))
        self.assertEqual(notify._soon_reasons(user("a", expires="0"), today), {})

    async def test_once_per_condition_after_seed(self):
        soon = (date.today() + timedelta(days=1)).isoformat()
        users = [user("old", 90 * GB, 100 * GB)]
        state = {}
        with patch.object(notify.cli, "secrets", AsyncMock(side_effect=lambda: users)), \
             patch.object(notify, "broadcast", AsyncMock()) as broadcast:
            await notify.check_limits_soon(None, state)        # засев — молча
            self.assertEqual(broadcast.await_count, 0)
            users.append(user("new", expires=soon))
            await notify.check_limits_soon(None, state)
            self.assertEqual(broadcast.await_count, 1)
            self.assertIn("new", broadcast.await_args.args[1])
            self.assertNotIn("old", broadcast.await_args.args[1])
            await notify.check_limits_soon(None, state)        # повтор — молча
            self.assertEqual(broadcast.await_count, 1)
            users[1]["expires"] = "0"                           # продлили
            await notify.check_limits_soon(None, state)
            users[1]["expires"] = soon                          # и снова подходит
            await notify.check_limits_soon(None, state)
            self.assertEqual(broadcast.await_count, 2)
            users.append(user("off", 95 * GB, 100 * GB, enabled=False))
            await notify.check_limits_soon(None, state)
            self.assertEqual(broadcast.await_count, 2)


class Weekly(unittest.IsolatedAsyncioTestCase):
    def test_text(self):
        users = [user("a", 30 * GB), user("b", 5 * GB), user("c", 1 * GB)]
        base = {"a": 10 * GB, "b": 5 * GB, "c": 4 * GB}     # у c сбросили счётчик
        text = notify.weekly_report_text(users, base, {"proxy_down": 2}, 0)
        self.assertIn("Трафик: <b>21", text)
        self.assertIn("1. a", text)
        self.assertNotIn(". b", text)
        self.assertIn("прокси не отвечал — 2", text)
        self.assertIn("Сбоев за неделю не было", notify.weekly_report_text(users, base, {}, 0))

    async def test_schedule(self):
        users = [user("a", 10 * GB)]
        state = {}
        monday = datetime(2026, 11, 2, 10, 5)
        sunday = datetime(2026, 11, 1, 12, 0)

        class FakeDT(datetime):
            now_value = sunday

            @classmethod
            def now(cls, tz=None):
                return cls.now_value

        with patch.object(notify, "datetime", FakeDT), \
             patch.object(notify.cli, "secrets", AsyncMock(side_effect=lambda: users)), \
             patch.object(notify.cli, "availability_status", AsyncMock(return_value={})), \
             patch.object(notify, "broadcast", AsyncMock()) as broadcast:
            await notify.check_weekly(None, state)      # точка отсчёта
            self.assertEqual(broadcast.await_count, 0)
            notify._count(state, "egress_switch")
            users[0]["total_bytes"] = 15 * GB
            FakeDT.now_value = monday
            await notify.check_weekly(None, state)
            self.assertEqual(broadcast.await_count, 1)
            self.assertIn("Трафик: <b>5", broadcast.await_args.args[1])
            self.assertIn("переключался — 1", broadcast.await_args.args[1])
            self.assertEqual(state["weekly_events"], {})
            await notify.check_weekly(None, state)      # тот же день — не дважды
            self.assertEqual(broadcast.await_count, 1)


if __name__ == "__main__":
    unittest.main()
